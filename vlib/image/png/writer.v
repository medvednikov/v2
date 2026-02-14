module png

import compress.zlib
import encoding.binary
import hash.crc32
import image
import image.color
import io
import strconv
// Encoder configures encoding PNG images.
pub struct Encoder {
pub mut:
	compression_level CompressionLevel
// BufferPool optionally specifies a buffer pool to get temporary
// EncoderBuffers when encoding an image.
	buffer_pool EncoderBufferPool
}

// EncoderBufferPool is an interface for getting and returning temporary
// instances of the [EncoderBuffer] struct. This can be used to reuse buffers
// when encoding multiple images.
pub interface EncoderBufferPool {
	get() &EncoderBuffer
	put(&EncoderBuffer)
}

// EncoderBuffer holds the buffers used for encoding PNG images.
type EncoderBuffer = Encoder
struct Encoder_1 {
pub mut:
	enc &Encoder = unsafe { nil }
	w io.Writer
	m image.Image
	cb isize
	err IError
	header [8]u8
	footer [4]u8
	tmp [4 * 256]u8
	cr [NFilter][]u8
	pr []u8
	zw &zlib.Writer = unsafe { nil }
	zw_level isize
	bw &bufio.Writer = unsafe { nil }
}

// CompressionLevel indicates the compression level.
type CompressionLevel = isize
pub const default_compression = 0
pub const no_compression = -1
pub const best_speed = -2
pub const best_compression = -3
interface opaquer {
	opaque() bool
}


// Returns whether or not the image is fully opaque.
fn opaque(m image.Image) bool {
mut ok := m is Opaquer
mut o := m as Opaquer
if ok{
return o.opaque()
}
mut b:=m.bounds()
for y:=b.min.y
; y < b.max.y; y++
{
for x:=b.min.x
; x < b.max.x; x++
{
_, _, _, a:=m.at(x, y).rgba()
if a != 0xffff{
return false
}
}
}
return true
}

// The absolute value of a byte interpreted as a signed int8.
fn abs8(d u8) isize {
if d < 128{
return isize(d)
}
return 256 - isize(d)
}

fn (mut e Encoder) write_chunk(b []u8,name string) {
if e.err != unsafe { nil }{
return 
}
mut n:=u32(b.len)
if isize(n) != b.len{
e.err=unsupported_error(name+' chunk is too large: ' + strconv.itoa(b.len))
return 
}
binary.big_endian_put_u32(mut e.header[..4], n)
e.header[4]=name[0]
e.header[5]=name[1]
e.header[6]=name[2]
e.header[7]=name[3]
mut crc:=crc32.new_ieee()
crc.write(e.header[4..8]) or { }
crc.write(b) or { }
binary.big_endian_put_u32(mut e.footer[..4], crc.sum32())
_, e.err=e.w.write(e.header[..8])
if e.err != unsafe { nil }{
return 
}
_, e.err=e.w.write(b)
if e.err != unsafe { nil }{
return 
}
_, e.err=e.w.write(e.footer[..4])
}

fn (mut e Encoder) write_ihdr() {
mut b:=e.m.bounds()
binary.big_endian_put_u32(mut e.tmp[0..4], u32(b.dx()))
binary.big_endian_put_u32(mut e.tmp[4..8], u32(b.dy()))
match e.cb{
cb_g8{
e.tmp[8]=8
e.tmp[9]=ct_grayscale
}
cb_tc_8{
e.tmp[8]=8
e.tmp[9]=ct_true_color
}
cb_p8{
e.tmp[8]=8
e.tmp[9]=ct_paletted
}
cb_p4{
e.tmp[8]=4
e.tmp[9]=ct_paletted
}
cb_p2{
e.tmp[8]=2
e.tmp[9]=ct_paletted
}
cb_p1{
e.tmp[8]=1
e.tmp[9]=ct_paletted
}
cb_tca_8{
e.tmp[8]=8
e.tmp[9]=ct_true_color_alpha
}
cb_g16{
e.tmp[8]=16
e.tmp[9]=ct_grayscale
}
cb_tc_16{
e.tmp[8]=16
e.tmp[9]=ct_true_color
}
cb_tca_16{
e.tmp[8]=16
e.tmp[9]=ct_true_color_alpha
}
}
e.tmp[10]=0
e.tmp[11]=0
e.tmp[12]=0
e.write_chunk(e.tmp[..13], 'IHDR')
}

fn (mut e Encoder) write_pltea_nd_trns(p color.Palette) {
if p.len < 1 || p.len > 256{
e.err=format_error('bad palette length: '+strconv.itoa(p.len))
return 
}
mut last:=-1
for i, c in p {
mut c1:=color.nrgbam_odel.convert(c)
e.tmp[3 * i+0]=c1.r
e.tmp[3 * i+1]=c1.g
e.tmp[3 * i+2]=c1.b
if c1.a != 0xff{
last=i
}
e.tmp[3 * 256 + i]=c1.a
}
e.write_chunk(e.tmp[..3 * p.len], 'PLTE')
if last != -1{
e.write_chunk(e.tmp[3 * 256..3 * 256+1 + last], 'tRNS')
}
}

// An encoder is an io.Writer that satisfies writes by writing PNG IDAT chunks,
// including an 8-byte header and 4-byte CRC checksum per Write call. Such calls
// should be relatively infrequent, since writeIDATs uses a [bufio.Writer].
//
// This method should only be called from writeIDATs (via writeImage).
// No other code should treat an encoder as an io.Writer.
pub fn (mut e Encoder) write(b []u8) (isize,IError) {
e.write_chunk(b, 'IDAT')
if e.err != unsafe { nil }{
return 0, e.err
}
return b.len, unsafe { nil }
}

// Chooses the filter to use for encoding the current row, and applies it.
// The return value is the index of the filter and also of the row in cr that has had it applied.
fn filter(cr [NFilter][]u8,pr []u8,bpp isize) isize {
mut cdat0:=cr[0][1..]
mut cdat1:=cr[1][1..]
mut cdat2:=cr[2][1..]
mut cdat3:=cr[3][1..]
mut cdat4:=cr[4][1..]
mut pdat:=pr[1..]
mut n:=cdat0.len
mut sum:=isize(0)
for i:=isize(0)
; i < n; i++
{
cdat2[i]=cdat0[i] - pdat[i]
sum+=abs8(cdat2[i])
}
mut best:=sum
mut filter:=ft_up
sum=0
for i:=isize(0)
; i < bpp; i++
{
cdat4[i]=cdat0[i] - pdat[i]
sum+=abs8(cdat4[i])
}
for i:=bpp
; i < n; i++
{
cdat4[i]=cdat0[i] - paeth(cdat0[i - bpp], pdat[i], pdat[i - bpp])
sum+=abs8(cdat4[i])
if sum >= best{
break
}
}
if sum < best{
best=sum
filter=ft_paeth
}
sum=0
for i:=isize(0)
; i < n; i++
{
sum+=abs8(cdat0[i])
if sum >= best{
break
}
}
if sum < best{
best=sum
filter=ft_none
}
sum=0
for i:=isize(0)
; i < bpp; i++
{
cdat1[i]=cdat0[i]
sum+=abs8(cdat1[i])
}
for i:=bpp
; i < n; i++
{
cdat1[i]=cdat0[i] - cdat0[i - bpp]
sum+=abs8(cdat1[i])
if sum >= best{
break
}
}
if sum < best{
best=sum
filter=ft_sub
}
sum=0
for i:=isize(0)
; i < bpp; i++
{
cdat3[i]=cdat0[i] - pdat[i] / 2
sum+=abs8(cdat3[i])
}
for i:=bpp
; i < n; i++
{
cdat3[i]=cdat0[i] - u8((isize(cdat0[i - bpp]) + isize(pdat[i])) / 2)
sum+=abs8(cdat3[i])
if sum >= best{
break
}
}
if sum < best{
filter=ft_average
}
return filter
}

fn (mut e Encoder) write_image(w io.Writer,m image.Image,cb isize,level isize) IError {
if e.zw == unsafe { nil } || e.zw_level != level{
mut zw, err:=zlib.new_writer_level(w, level)
if err != unsafe { nil }{
return err
}
e.zw=zw
e.zw_level=level
}
else
{
e.zw.reset(w)
}
defer {
e.zw.close()
}
mut bits_per_pixel:=isize(0)
match cb{
cb_g8{
bits_per_pixel=8
}
cb_tc_8{
bits_per_pixel=24
}
cb_p8{
bits_per_pixel=8
}
cb_p4{
bits_per_pixel=4
}
cb_p2{
bits_per_pixel=2
}
cb_p1{
bits_per_pixel=1
}
cb_tca_8{
bits_per_pixel=32
}
cb_tc_16{
bits_per_pixel=48
}
cb_tca_16{
bits_per_pixel=64
}
cb_g16{
bits_per_pixel=16
}
}
mut b:=m.bounds()
mut sz:=1+(bits_per_pixel * b.dx()+7) / 8
for i,  _  in e.cr {
if e.cr[i].cap < sz{
e.cr[i]=[]u8{len: sz}
}
else
{
e.cr[i]=e.cr[i][..sz]
}
e.cr[i][0]=u8(i)
}
mut cr:=e.cr
if e.pr.cap < sz{
e.pr=[]u8{len: sz}
}
else
{
e.pr=e.pr[..sz]
clear(e.pr)
}
mut pr:=e.pr
mut gray := m as &image.Gray
mut rgba := m as &image.RGBA
mut paletted := m as &image.Paletted
mut nrgba := m as &image.NRGBA
for y:=b.min.y
; y < b.max.y; y++
{
mut i_1:=isize(1)
match cb{
cb_g8{
if gray != unsafe { nil }{
mut offset:=(y - b.min.y) * gray.stride
copy(cr[0][1..], gray.pix[offset..offset + b.dx()])
}
else
{
for x:=b.min.x
; x < b.max.x; x++
{
mut c:=color.gray_model.convert(m.at(x, y))
cr[0][i_1]=c.y
i_1++
}
}
}
cb_tc_8{
mut cr0:=cr[0]
mut stride, pix:=isize(0), unsafe { nil }.bytes()
if rgba != unsafe { nil }{
stride, pix=rgba.stride, rgba.pix
}
else
if nrgba != unsafe { nil }{
stride, pix=nrgba.stride, nrgba.pix
}
if stride != 0{
mut j0:=(y - b.min.y) * stride
mut j1:=j0 + b.dx() * 4
for j:=j0
; j < j1; j+=4
{
cr0[i_1+0]=pix[j+0]
cr0[i_1+1]=pix[j+1]
cr0[i_1+2]=pix[j+2]
i+=3
}
}
else
{
for x:=b.min.x
; x < b.max.x; x++
{
mut r, g, b_1, _:=m.at(x, y).rgba()
cr0[i_1+0]=u8(r >> 8)
cr0[i_1+1]=u8(g >> 8)
cr0[i_1+2]=u8(b_1 >> 8)
i+=3
}
}
}
cb_p8{
if paletted != unsafe { nil }{
mut offset_1:=(y - b_1.min.y) * paletted.stride
copy(cr[0][1..], paletted.pix[offset_1..offset_1 + b_1.dx()])
}
else
{
mut pi:=m
for x:=b_1.min.x
; x < b_1.max.x; x++
{
cr[0][i_1]=pi.color_index_at(x, y)
i+=1
}
}
}
cb_p4,cb_p2,cb_p1{
mut pi_1:=m
mut a := 0

mut c_1 := 0

mut pixels_per_byte:=8 / bits_per_pixel
for x:=b_1.min.x
; x < b_1.max.x; x++
{
a=a << usize(bits_per_pixel) | pi_1.color_index_at(x, y)
c_1++
if c_1 == pixels_per_byte{
cr[0][i_1]=a
i+=1
a=0
c=0
}
}
if c_1 != 0{
for c_1 != pixels_per_byte{
a=a << usize(bits_per_pixel)
c_1++
}
cr[0][i_1]=a
}
}
cb_tca_8{
if nrgba != unsafe { nil }{
mut offset_2:=(y - b_1.min.y) * nrgba.stride
copy(cr[0][1..], nrgba.pix[offset_2..offset_2 + b_1.dx() * 4])
}
else
if rgba != unsafe { nil }{
mut dst:=cr[0][1..]
mut src:=rgba.pix[rgba.pix_offset(b_1.min.x, y)..rgba.pix_offset(b_1.max.x, y)]
for ; src.len >= 4; dst, src=dst[4..], src[4..]
{
mut d:=(*[4]u8)()
mut s:=(*[4]u8)()
if s[3] == 0x00{
d[0]=0
d[1]=0
d[2]=0
d[3]=0
}
else
if s[3] == 0xff{
copy(d[..], s[..])
}
else
{

mut a_1:=u32(s[3]) * 0x101
d[0]=u8((u32(s[0]) * m / a_1) >> 8)
d[1]=u8((u32(s[1]) * m / a_1) >> 8)
d[2]=u8((u32(s[2]) * m / a_1) >> 8)
d[3]=s[3]
}
}
}
else
{
for x:=b_1.min.x
; x < b_1.max.x; x++
{
mut c_2:=color.nrgbam_odel.convert(m.at(x, y))
cr[0][i_1+0]=c_2.r
cr[0][i_1+1]=c_2.g
cr[0][i_1+2]=c_2.b
cr[0][i_1+3]=c_2.a
i+=4
}
}
}
cb_g16{
for x:=b_1.min.x
; x < b_1.max.x; x++
{
mut c_3:=color.gray16_model.convert(m.at(x, y))
cr[0][i_1+0]=u8(c_3.y >> 8)
cr[0][i_1+1]=u8(c_3.y)
i+=2
}
}
cb_tc_16{
for x:=b_1.min.x
; x < b_1.max.x; x++
{
mut r_1, g_1, b_2, _:=m.at(x, y).rgba()
cr[0][i_1+0]=u8(r_1 >> 8)
cr[0][i_1+1]=u8(r_1)
cr[0][i_1+2]=u8(g_1 >> 8)
cr[0][i_1+3]=u8(g_1)
cr[0][i_1+4]=u8(b_2 >> 8)
cr[0][i_1+5]=u8(b_2)
i+=6
}
}
cb_tca_16{
for x:=b_2.min.x
; x < b_2.max.x; x++
{
mut c_4:=color.nrgba_64_model.convert(m.at(x, y))
cr[0][i_1+0]=u8(c_4.r >> 8)
cr[0][i_1+1]=u8(c_4.r)
cr[0][i_1+2]=u8(c_4.g >> 8)
cr[0][i_1+3]=u8(c_4.g)
cr[0][i_1+4]=u8(c_4.b >> 8)
cr[0][i_1+5]=u8(c_4.b)
cr[0][i_1+6]=u8(c_4.a >> 8)
cr[0][i_1+7]=u8(c_4.a)
i+=8
}
}
}
mut f:=ft_none
if level != zlib.no_compression && cb != cb_p8 && cb != cb_p4 && cb != cb_p2 && cb != cb_p1{
mut bpp:=bits_per_pixel / 8
f=filter(&cr, pr, bpp)
}
_, err_1:=e.zw.write(cr[f])
if err_1 != unsafe { nil }{
return err_1
}
pr, cr[0]=cr[0], pr
}
return unsafe { nil }
}

// Write the actual image data to one or more IDAT chunks.
fn (mut e Encoder) write_idat_s() {
if e.err != unsafe { nil }{
return 
}
if e.bw == unsafe { nil }{
e.bw=bufio.new_writer_size(e, 1 << 15)
}
else
{
e.bw.reset(e)
}
e.err=e.write_image(e.bw, e.m, e.cb, level_to_zlib(e.enc.compression_level))
if e.err != unsafe { nil }{
return 
}
e.err=e.bw.flush()
}

// This function is required because we want the zero value of
// Encoder.CompressionLevel to map to zlib.DefaultCompression.
fn level_to_zlib(l CompressionLevel) isize {
match l{
default_compression{
return zlib.default_compression
}
no_compression{
return zlib.no_compression
}
best_speed{
return zlib.best_speed
}
best_compression{
return zlib.best_compression
}
else {
return zlib.default_compression
}
}
}

fn (mut e Encoder) write_iend() {
e.write_chunk(unsafe { nil }, 'IEND')
}

// Encode writes the Image m to w in PNG format. Any Image may be
// encoded, but images that are not [image.NRGBA] might be encoded lossily.
pub fn encode(w io.Writer,m image.Image) IError {
mut e := Encoder{}

return e.encode(w, m)
}

// Encode writes the Image m to w in PNG format.
pub fn (mut enc Encoder) encode_1(w io.Writer,m image.Image) IError {
mut mw, mh:=i64(m.bounds().dx()), i64(m.bounds().dy())
if mw <= 0 || mh <= 0 || mw >= 1 << 32 || mh >= 1 << 32{
return format_error('invalid image size: '+strconv.format_int(mw, 10)+'x' + strconv.format_int(mh, 10))
}
mut e := unsafe { nil }
if enc.buffer_pool != unsafe { nil }{
mut buffer:=enc.buffer_pool.get()
e=(*encoder)()
}
if e == unsafe { nil }{
e=&Encoder{}
}
if enc.buffer_pool != unsafe { nil }{
defer {
enc.buffer_pool.put((*encoder_buffer)())}
}
e.enc=enc
e.w=w
e.m=m
mut pal := color.Palette{}

mut ok := m is image.PalettedImage
if ok{
mut pal_1 := m.color_model() as color.Palette
}
if pal_1 != unsafe { nil }{
if pal_1.len <= 2{
e.cb=cb_p1
}
else
if pal_1.len <= 4{
e.cb=cb_p2
}
else
if pal_1.len <= 16{
e.cb=cb_p4
}
else
{
e.cb=cb_p8
}
}
else
{
match m.color_model(){
color.gray_model{
e.cb=cb_g8
}
color.gray16_model{
e.cb=cb_g16
}
color.rgbam_odel,color.nrgbam_odel,color.alpha_model{
if opaque(m){
e.cb=cb_tc_8
}
else
{
e.cb=cb_tca_8
}
}
else {
if opaque(m){
e.cb=cb_tc_16
}
else
{
e.cb=cb_tca_16
}
}
}
}
_, e.err=io.write_string(w, png_header)
e.write_ihdr()
if pal_1 != unsafe { nil }{
e.write_pltea_nd_trns(pal_1)
}
e.write_idat_s()
e.write_iend()
return e.err
}
