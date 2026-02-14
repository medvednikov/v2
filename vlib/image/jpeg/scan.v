module jpeg

import image

// makeImg allocates and initializes the destination image.
fn (mut d Decoder) make_img(mxx isize,myy isize) {
if d.n_comp == 1{
mut m:=image.new_gray(image.rect(0, 0, 8 * mxx, 8 * myy))
d.img1=m.sub_image(image.rect(0, 0, d.width, d.height))
return 
}
mut h0:=d.comp[0].h
mut v0:=d.comp[0].v
mut h_ratio:=h0 / d.comp[1].h
mut v_ratio:=v0 / d.comp[1].v
mut subsample_ratio := image.YCbCrSubsampleRatio{}

match h_ratio << 4 | v_ratio{
0x11{
subsample_ratio=image.yc_b_cr_subsample_ratio444
}
0x12{
subsample_ratio=image.yc_b_cr_subsample_ratio440
}
0x21{
subsample_ratio=image.yc_b_cr_subsample_ratio422
}
0x22{
subsample_ratio=image.yc_b_cr_subsample_ratio420
}
0x41{
subsample_ratio=image.yc_b_cr_subsample_ratio411
}
0x42{
subsample_ratio=image.yc_b_cr_subsample_ratio410
}
}
mut m_1:=image.new_yc_b_cr(image.rect(0, 0, 8 * h0 * mxx, 8 * v0 * myy), subsample_ratio)
d.img3=m_1.sub_image(image.rect(0, 0, d.width, d.height))
if d.n_comp == 4{
mut h3, v3:=d.comp[3].h, d.comp[3].v
d.black_pix=[]u8{len: 8 * h3 * mxx * 8 * v3 * myy}
d.black_stride=8 * h3 * mxx
}
}

// Specified in section B.2.3.
fn (mut d Decoder) process_sos(n isize) IError {
if d.n_comp == 0{
return format_error('missing SOF marker')
}
if n < 6 || 4+2 * d.n_comp < n || n % 2 != 0{
return format_error('SOS has wrong length')
}
mut err:=d.read_full(d.tmp[..n])
if err != unsafe { nil }{
return err
}
mut n_comp:=isize(d.tmp[0])
if n != 4+2 * n_comp{
return format_error('SOS length inconsistent with number of components')
}
mut scan := [max_components]struct { CompIndex u8 td u8 ta u8 }{}

mut total_hv:=isize(0)
for i:=isize(0)
; i < n_comp; i++
{
mut cs:=d.tmp[1+2 * i]
mut comp_index:=-1
for j, comp in d.comp[..d.n_comp] {
if cs == comp.c{
comp_index=j
}
}
if comp_index < 0{
return format_error('unknown component selector')
}
scan[i].comp_index=u8(comp_index)
for j_1:=isize(0)
; j_1 < i; j_1++
{
if scan[i].comp_index == scan[j_1].comp_index{
return format_error('repeated component selector')
}
}
total_hv+=d.comp[comp_index].h * d.comp[comp_index].v
scan[i].td=d.tmp[2+2 * i] >> 4
mut t:=scan[i].td
if t > max_th || (d.baseline && t > 1){
return format_error('bad Td value')
}
scan[i].ta=d.tmp[2+2 * i] & 0x0f
mut t_1:=scan[i].ta
if t_1 > max_th || (d.baseline && t_1 > 1){
return format_error('bad Ta value')
}
}
if d.n_comp > 1 && total_hv > 10{
return format_error('total sampling factors too large')
}
mut zig_start, zig_end, ah, al:=i32(0), i32(block_size - 1), u32(0), u32(0)
if d.progressive{
zig_start=i32(d.tmp[1+2 * n_comp])
zig_end=i32(d.tmp[2+2 * n_comp])
ah=u32(d.tmp[3+2 * n_comp] >> 4)
al=u32(d.tmp[3+2 * n_comp] & 0x0f)
if (zig_start == 0 && zig_end != 0) || zig_start > zig_end || block_size <= zig_end{
return format_error('bad spectral selection bounds')
}
if zig_start != 0 && n_comp != 1{
return format_error('progressive AC coefficients for more than one component')
}
if ah != 0 && ah != al+1{
return format_error('bad successive approximation values')
}
}
mut h0, v0:=d.comp[0].h, d.comp[0].v
mut mxx:=(d.width + 8 * h0 - 1) / (8 * h0)
mut myy:=(d.height + 8 * v0 - 1) / (8 * v0)
if d.img1 == unsafe { nil } && d.img3 == unsafe { nil }{
d.make_img(mxx, myy)
}
if d.progressive{
for i:=isize(0)
; i < n_comp; i++
{
mut comp_index_1:=scan[i].comp_index
if d.prog_coeffs[comp_index_1] == unsafe { nil }{
d.prog_coeffs[comp_index_1]=[]Block{len: mxx * myy * d.comp[comp_index_1].h * d.comp[comp_index_1].v}
}
}
}
d.bits=Bits{}
mut mcu, expected_rst:=isize(0), u8(rst0_marker)
mut b := Block{}
mut dc := [max_components]i32{}
mut bx,by := 0
mut block_count := 0

for my:=isize(0)
; my < myy; my++
{
for mx:=isize(0)
; mx < mxx; mx++
{
for i:=isize(0)
; i < n_comp; i++
{
mut comp_index_2:=scan[i].comp_index
mut hi:=d.comp[comp_index_2].h
mut vi:=d.comp[comp_index_2].v
for j:=isize(0)
; j_1 < hi * vi; j_1++
{
if n_comp != 1{
bx=hi * mx + j_1 % hi
by=vi * my + j_1 / hi
}
else
{
mut q:=mxx * hi
bx=block_count % q
by=block_count / q
block_count++
if bx * 8 >= d.width || by * 8 >= d.height{
continue
}
}
if d.progressive{
b=d.prog_coeffs[comp_index_2][by * mxx * hi + bx]
}
else
{
b=Block{}
}
if ah != 0{
mut err_1:=d.refine(&b, &d.huff[ac_table][scan[i].ta], zig_start, zig_end, 1 << al)
if err_1 != unsafe { nil }{
return err_1
}
}
else
{
mut zig:=zig_start
if zig == 0{
zig++
mut value, err_2:=d.decode_huffman(&d.huff[dc_table][scan[i].td])
if err_2 != unsafe { nil }{
return err_2
}
if value > 16{
return unsupported_error('excessive DC component')
}
mut dc_delta, err_3:=d.receive_extend(value)
if err_3 != unsafe { nil }{
return err_3
}
dc[comp_index_2]+=dc_delta
b[0]=dc[comp_index_2] << al
}
if zig <= zig_end && d.eob_run > 0{
d.eob_run--
}
else
{
mut huff:=&d.huff[ac_table][scan[i].ta]
for ; zig <= zig_end; zig++
{
mut value_1, err_4:=d.decode_huffman(huff)
if err_4 != unsafe { nil }{
return err_4
}
mut val0:=value_1 >> 4
mut val1:=value_1 & 0x0f
if val1 != 0{
zig+=i32(val0)
if zig > zig_end{
break
}
mut ac, err_5:=d.receive_extend(val1)
if err_5 != unsafe { nil }{
return err_5
}
b[unzig[zig]]=ac << al
}
else
{
if val0 != 0x0f{
d.eob_run=u16(1 << val0)
if val0 != 0{
mut bits, err_6:=d.decode_bits(i32(val0))
if err_6 != unsafe { nil }{
return err_6
}
d.eob_run|=u16(bits)
}
d.eob_run--
break
}
zig+=0x0f
}
}
}
}
if d.progressive{
d.prog_coeffs[comp_index_2][by * mxx * hi + bx]=b
continue
}
mut err_7:=d.reconstruct_block(&b, bx, by, isize(comp_index_2))
if err_7 != unsafe { nil }{
return err_7
}
}
}
mcu++
if d.ri > 0 && mcu % d.ri == 0 && mcu < mxx * myy{
mut err_8:=d.read_full(d.tmp[..2])
if err_8 != unsafe { nil }{
return err_8
}
else
if d.tmp[0] != 0xff || d.tmp[1] != expected_rst{
mut err_9:=d.find_rst(expected_rst)
if err_9 != unsafe { nil }{
return err_9
}
}
expected_rst++
if expected_rst == rst7_marker+1{
expected_rst=rst0_marker
}
d.bits=Bits{}
dc=[]i32{}
d.eob_run=0
}
}
}
return unsafe { nil }
}

// refine decodes a successive approximation refinement block, as specified in
// section G.1.2.
fn (mut d Decoder) refine(b &Block,h &Huffman,zig_start i32,zig_end i32,delta i32) IError {
if zig_start == 0{
if zig_end != 0{
panic('unreachable')
}
mut bit, err:=d.decode_bit()
if err != unsafe { nil }{
return err
}
if bit{
b[0]|=delta
}
return unsafe { nil }
}
mut zig:=zig_start
if d.eob_run == 0{
loop:
for ; zig <= zig_end; zig++
{
mut z:=i32(0)
mut value, err_1:=d.decode_huffman(h)
if err_1 != unsafe { nil }{
return err_1
}
mut val0:=value >> 4
mut val1:=value & 0x0f
match val1{
0{
if val0 != 0x0f{
d.eob_run=u16(1 << val0)
if val0 != 0{
mut bits, err_2:=d.decode_bits(i32(val0))
if err_2 != unsafe { nil }{
return err_2
}
d.eob_run|=u16(bits)
}
break loop
}
}
1{
z=delta
mut bit_1, err_3:=d.decode_bit()
if err_3 != unsafe { nil }{
return err_3
}
if !bit_1{
z=-z
}
}
else {
return format_error('unexpected Huffman code')
}
}
zig, err=d.refine_non_zeroes(b, zig, zig_end, i32(val0), delta)
if err_3 != unsafe { nil }{
return err_3
}
if zig > zig_end{
return format_error('too many coefficients')
}
if z != 0{
b[unzig[zig]]=z
}
}
}
if d.eob_run > 0{
d.eob_run--
_, err_4:=d.refine_non_zeroes(b, zig, zig_end, -1, delta)
if err_4 != unsafe { nil }{
return err_4
}
}
return unsafe { nil }
}

// refineNonZeroes refines non-zero entries of b in zig-zag order. If nz >= 0,
// the first nz zero entries are skipped over.
fn (mut d Decoder) refine_non_zeroes(b &Block,zig i32,zig_end i32,nz i32,delta i32) (i32,IError) {
for ; zig <= zig_end; zig++
{
mut u:=unzig[zig]
if b[u] == 0{
if nz == 0{
break
}
nz--
continue
}
mut bit, err:=d.decode_bit()
if err != unsafe { nil }{
return 0, err
}
if !bit{
continue
}
if b[u] >= 0{
b[u]+=delta
}
else
{
b[u]-=delta
}
}
return zig, unsafe { nil }
}

fn (mut d Decoder) reconstruct_progressive_image() IError {
mut h0:=d.comp[0].h
mut mxx:=(d.width + 8 * h0 - 1) / (8 * h0)
for i:=isize(0)
; i < d.n_comp; i++
{
if d.prog_coeffs[i] == unsafe { nil }{
continue
}
mut v:=8 * d.comp[0].v / d.comp[i].v
mut h:=8 * d.comp[0].h / d.comp[i].h
mut stride:=mxx * d.comp[i].h
for by:=isize(0)
; by * v < d.height; by++
{
for bx:=isize(0)
; bx * h < d.width; bx++
{
mut err:=d.reconstruct_block(&d.prog_coeffs[i][by * stride + bx], bx, by, i)
if err != unsafe { nil }{
return err
}
}
}
}
return unsafe { nil }
}

// reconstructBlock dequantizes, performs the inverse DCT and stores the block
// to the image.
fn (mut d Decoder) reconstruct_block(b &Block,bx isize,by isize,comp_index isize) IError {
mut qt:=&d.quant[d.comp[comp_index].tq]
for zig:=isize(0)
; zig < block_size; zig++
{
b[unzig[zig]]*=qt[zig]
}
idct(b)
mut dst, stride:=unsafe { nil }.bytes(), isize(0)
if d.n_comp == 1{
dst, stride=d.img1.pix[8 * (by * d.img1.stride + bx)..], d.img1.stride
}
else
{
match comp_index{
0{
dst, stride=d.img3.y[8 * (by * d.img3.ys_tride + bx)..], d.img3.ys_tride
}
1{
dst, stride=d.img3.cb[8 * (by * d.img3.cs_tride + bx)..], d.img3.cs_tride
}
2{
dst, stride=d.img3.cr[8 * (by * d.img3.cs_tride + bx)..], d.img3.cs_tride
}
3{
dst, stride=d.black_pix[8 * (by * d.black_stride + bx)..], d.black_stride
}
else {
return unsupported_error('too many components')
}
}
}
for y:=isize(0)
; y < 8; y++
{
mut y8:=y * 8
mut y_stride:=y * stride
for x:=isize(0)
; x < 8; x++
{
mut c:=b[y8 + x]
if c < -128{
c=0
}
else
if c > 127{
c=255
}
else
{
c+=128
}
dst[y_stride + x]=u8(c)
}
}
return unsafe { nil }
}

// findRST advances past the next RST restart marker that matches expectedRST.
// Other than I/O errors, it is also an error if we encounter an {0xFF, M}
// two-byte marker sequence where M is not 0x00, 0xFF or the expectedRST.
//
// This is similar to libjpeg's jdmarker.c's next_marker function.
// https://github.com/libjpeg-turbo/libjpeg-turbo/blob/2dfe6c0fe9e18671105e94f7cbf044d4a1d157e6/jdmarker.c#L892-L935
//
// Precondition: d.tmp[:2] holds the next two bytes of JPEG-encoded input
// (input in the d.readFull sense).
fn (mut d Decoder) find_rst(expected_rst u8) IError {
for {
mut i:=isize(0)
if d.tmp[0] == 0xff{
if d.tmp[1] == expected_rst{
return unsafe { nil }
}
else
if d.tmp[1] == 0xff{
i=1
}
else
if d.tmp[1] != 0x00{
return format_error('bad RST marker')
}
}
else
if d.tmp[1] == 0xff{
d.tmp[0]=0xff
i=1
}
mut err:=d.read_full(d.tmp[i..2])
if err != unsafe { nil }{
return err
}
}
}
