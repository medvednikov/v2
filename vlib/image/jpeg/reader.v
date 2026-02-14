module jpeg

import image
import image.color
import image.internal.imageutil
import io
// A FormatError reports that the input is not a valid JPEG.
type FormatError = string

pub fn (e FormatError) error_() string {
return 'invalid JPEG format: '+e.str()

}
// An UnsupportedError reports that the input uses a valid but unimplemented JPEG feature.
type UnsupportedError = string

pub fn (e UnsupportedError) error__1() string {
return 'unsupported JPEG feature: '+e.str()

}
__global err_unsupported_subsampling_ratio = unsupported_error('luma/chroma subsampling ratio')
// Component specification, specified in section B.2.2.
struct Component {
pub mut:
	h isize
	v isize
	c u8
	tq u8
}

const dc_table = 0
const ac_table = 1
const max_tc = 1
const max_th = 3
const max_tq = 3
const max_components = 4
const sof0_marker = 0xc0
const sof1_marker = 0xc1
const sof2_marker = 0xc2
const dht_marker = 0xc4
const rst0_marker = 0xd0
const rst7_marker = 0xd7
const soi_marker = 0xd8
const eoi_marker = 0xd9
const sos_marker = 0xda
const dqt_marker = 0xdb
const dri_marker = 0xdd
const com_marker = 0xfe
const app0_marker = 0xe0
const app14_marker = 0xee
const app15_marker = 0xef
// See https://www.sno.phy.queensu.ca/~phil/exiftool/TagNames/JPEG.html#Adobe
const adobe_transform_unknown = 0
const adobe_transform_yc_b_cr = 1
const adobe_transform_yc_b_cr_k = 2
// unzig maps from the zig-zag ordering to the natural ordering. For example,
// unzig[3] is the column and row of the fourth element in zig-zag order. The
// value is 16, which means first column (16%8 == 0) and third row (16/8 == 2).
__global unzig = [isize(0),1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]!
// Deprecated: Reader is not used by the [image/jpeg] package and should
// not be used by others. It is kept for compatibility.
pub interface Reader {
}

// bits holds the unprocessed bits that have been taken from the byte-stream.
// The n least significant bits of a form the unread bits, to be read in MSB to
// LSB order.
struct Bits {
pub mut:
	a u32
	m u32
	n i32
}

struct Decoder {
pub mut:
	r io.Reader
	bits Bits
// bytes is a byte buffer, similar to a bufio.Reader, except that it
// has to be able to unread more than 1 byte, due to byte stuffing.
// Byte stuffing is specified in section F.1.2.3.
	bytes struct { Buf [4096]u8 i isize j isize n_unreadable isize }
	width isize
	height isize
	img1 &image.Gray = unsafe { nil }
	img3 &image.YCbCr = unsafe { nil }
	black_pix []u8
	black_stride isize
	ri isize
	n_comp isize
// As per section 4.5, there are four modes of operation (selected by the
// SOF? markers): sequential DCT, progressive DCT, lossless and
// hierarchical, although this implementation does not support the latter
// two non-DCT modes. Sequential DCT is further split into baseline and
// extended, as per section 4.11.
	baseline bool
	progressive bool
	jfif bool
	adobe_transform_valid bool
	adobe_transform u8
	eob_run u16
	comp [MaxComponents]Component
	prog_coeffs [MaxComponents][]Block
	huff [MaxTc+1][MaxTh+1]Huffman
	quant [MaxTq+1]Block
	tmp [2 * BlockSize]u8
}


// fill fills up the d.bytes.buf buffer from the underlying io.Reader. It
// should only be called when there are no unread bytes in d.bytes.
fn (mut d Decoder) fill() IError {
if d.bytes.i != d.bytes.j{
panic('jpeg: fill called when unread bytes exist')
}
if d.bytes.j > 2{
d.bytes.buf[0]=d.bytes.buf[d.bytes.j - 2]
d.bytes.buf[1]=d.bytes.buf[d.bytes.j - 1]
d.bytes.i, d.bytes.j=2, 2
}
mut n, err:=d.r.read(d.bytes.buf[d.bytes.j..])
d.bytes.j+=n
if n > 0{
return unsafe { nil }
}
if err == io.eof{
err=io.err_unexpected_eof
}
return err
}

// unreadByteStuffedByte undoes the most recent readByteStuffedByte call,
// giving a byte of data back from d.bits to d.bytes. The Huffman look-up table
// requires at least 8 bits for look-up, which means that Huffman decoding can
// sometimes overshoot and read one or two too many bytes. Two-byte overshoot
// can happen when expecting to read a 0xff 0x00 byte-stuffed byte.
fn (mut d Decoder) unread_byte_stuffed_byte() {
d.bytes.i-=d.bytes.n_unreadable
d.bytes.n_unreadable=0
if d.bits.n >= 8{
d.bits.a>>=8
d.bits.n-=8
d.bits.m>>=8
}
}

// readByte returns the next byte, whether buffered or not buffered. It does
// not care about byte stuffing.
fn (mut d Decoder) read_byte() (u8,IError) {
mut x:=0
mut err:=IError{}
for d.bytes.i == d.bytes.j{
err=d.fill()
if err != unsafe { nil }{
return 0, err
}
}
x=d.bytes.buf[d.bytes.i]
d.bytes.i++
d.bytes.n_unreadable=0
return x, unsafe { nil }
}
// errMissingFF00 means that readByteStuffedByte encountered an 0xff byte (a
// marker byte) that wasn't the expected byte-stuffed sequence 0xff, 0x00.
__global err_missing_ff_00 = format_error('missing 0xff00 sequence')

// readByteStuffedByte is like readByte but is for byte-stuffed Huffman data.
fn (mut d Decoder) read_byte_stuffed_byte() (u8,IError) {
mut x:=0
mut err:=IError{}
if d.bytes.i+2 <= d.bytes.j{
x=d.bytes.buf[d.bytes.i]
d.bytes.i++
d.bytes.n_unreadable=1
if x != 0xff{
return x, err
}
if d.bytes.buf[d.bytes.i] != 0x00{
return 0, err_missing_ff_00
}
d.bytes.i++
d.bytes.n_unreadable=2
return 0xff, unsafe { nil }
}
d.bytes.n_unreadable=0
x, err=d.read_byte()
if err != unsafe { nil }{
return 0, err
}
d.bytes.n_unreadable=1
if x != 0xff{
return x, unsafe { nil }
}
x, err=d.read_byte()
if err != unsafe { nil }{
return 0, err
}
d.bytes.n_unreadable=2
if x != 0x00{
return 0, err_missing_ff_00
}
return 0xff, unsafe { nil }
}

// readFull reads exactly len(p) bytes into p. It does not care about byte
// stuffing.
fn (mut d Decoder) read_full(p []u8) IError {
if d.bytes.n_unreadable != 0{
if d.bits.n >= 8{
d.unread_byte_stuffed_byte()
}
d.bytes.n_unreadable=0
}
for {
mut n:=copy(p, d.bytes.buf[d.bytes.i..d.bytes.j])
p=p[n..]
d.bytes.i+=n
if p.len == 0{
break
}
mut err:=d.fill()
if err != unsafe { nil }{
return err
}
}
return unsafe { nil }
}

// ignore ignores the next n bytes.
fn (mut d Decoder) ignore(n isize) IError {
if d.bytes.n_unreadable != 0{
if d.bits.n >= 8{
d.unread_byte_stuffed_byte()
}
d.bytes.n_unreadable=0
}
for {
mut m:=d.bytes.j - d.bytes.i
if m > n{
m=n
}
d.bytes.i+=m
n-=m
if n == 0{
break
}
mut err:=d.fill()
if err != unsafe { nil }{
return err
}
}
return unsafe { nil }
}

// Specified in section B.2.2.
fn (mut d Decoder) process_sof(n isize) IError {
if d.n_comp != 0{
return format_error('multiple SOF markers')
}
match n{
6+3 * 1{
d.n_comp=1
}
6+3 * 3{
d.n_comp=3
}
6+3 * 4{
d.n_comp=4
}
else {
return unsupported_error('number of components')
}
}
mut err:=d.read_full(d.tmp[..n])
if err != unsafe { nil }{
return err
}
if d.tmp[0] != 8{
return unsupported_error('precision')
}
d.height=isize(d.tmp[1]) << 8 + isize(d.tmp[2])
d.width=isize(d.tmp[3]) << 8 + isize(d.tmp[4])
if isize(d.tmp[5]) != d.n_comp{
return format_error('SOF has wrong length')
}
for i:=isize(0)
; i < d.n_comp; i++
{
d.comp[i].c=d.tmp[6+3 * i]
for j:=isize(0)
; j < i; j++
{
if d.comp[i].c == d.comp[j].c{
return format_error('repeated component identifier')
}
}
d.comp[i].tq=d.tmp[8+3 * i]
if d.comp[i].tq > max_tq{
return format_error('bad Tq value')
}
mut hv:=d.tmp[7+3 * i]
mut h, v:=isize(hv >> 4), isize(hv & 0x0f)
if h < 1 || 4 < h || v < 1 || 4 < v{
return format_error('luma/chroma subsampling ratio')
}
if h == 3 || v == 3{
return err_unsupported_subsampling_ratio
}
match d.n_comp{
1{
h, v=1, 1
}
3{
match i{
0{
if v == 4{
return err_unsupported_subsampling_ratio
}
}
1{
if d.comp[0].h % h != 0 || d.comp[0].v % v != 0{
return err_unsupported_subsampling_ratio
}
}
2{
if d.comp[1].h != h || d.comp[1].v != v{
return err_unsupported_subsampling_ratio
}
}
}
}
4{
match i{
0{
if hv != 0x11 && hv != 0x22{
return err_unsupported_subsampling_ratio
}
}
1,2{
if hv != 0x11{
return err_unsupported_subsampling_ratio
}
}
3{
if d.comp[0].h != h || d.comp[0].v != v{
return err_unsupported_subsampling_ratio
}
}
}
}
}
d.comp[i].h=h
d.comp[i].v=v
}
return unsafe { nil }
}

// Specified in section B.2.4.1.
fn (mut d Decoder) process_dqt(n isize) IError {
loop:
for n > 0{
n--
mut x, err:=d.read_byte()
if err != unsafe { nil }{
return err
}
mut tq:=x & 0x0f
if tq > max_tq{
return format_error('bad Tq value')
}
match x >> 4{
else {
return format_error('bad Pq value')
}
0{
if n < block_size{
break loop
}
n-=block_size
mut err_1:=d.read_full(d.tmp[..block_size])
if err_1 != unsafe { nil }{
return err_1
}
for i,  _  in d.quant[tq] {
d.quant[tq][i]=i32(d.tmp[i])
}
}
1{
if n < 2 * block_size{
break loop
}
n-=2 * block_size
mut err_2:=d.read_full(d.tmp[..2 * block_size])
if err_2 != unsafe { nil }{
return err_2
}
for i_1,  _  in d.quant[tq] {
d.quant[tq][i_1]=i32(d.tmp[2 * i_1]) << 8 | i32(d.tmp[2 * i_1+1])
}
}
}
}
if n != 0{
return format_error('DQT has wrong length')
}
return unsafe { nil }
}

// Specified in section B.2.4.4.
fn (mut d Decoder) process_dri(n isize) IError {
if n != 2{
return format_error('DRI has wrong length')
}
mut err:=d.read_full(d.tmp[..2])
if err != unsafe { nil }{
return err
}
d.ri=isize(d.tmp[0]) << 8 + isize(d.tmp[1])
return unsafe { nil }
}

fn (mut d Decoder) process_app0_marker(n isize) IError {
if n < 5{
return d.ignore(n)
}
mut err:=d.read_full(d.tmp[..5])
if err != unsafe { nil }{
return err
}
n-=5
d.jfif=d.tmp[0] == `J` && d.tmp[1] == `F` && d.tmp[2] == `I` && d.tmp[3] == `F` && d.tmp[4] == `\x00`
if n > 0{
return d.ignore(n)
}
return unsafe { nil }
}

fn (mut d Decoder) process_app14_marker(n isize) IError {
if n < 12{
return d.ignore(n)
}
mut err:=d.read_full(d.tmp[..12])
if err != unsafe { nil }{
return err
}
n-=12
if d.tmp[0] == `A` && d.tmp[1] == `d` && d.tmp[2] == `o` && d.tmp[3] == `b` && d.tmp[4] == `e`{
d.adobe_transform_valid=true
d.adobe_transform=d.tmp[11]
}
if n > 0{
return d.ignore(n)
}
return unsafe { nil }
}

// decode reads a JPEG image from r and returns it as an image.Image.
fn (mut d Decoder) decode(r io.Reader,config_only bool) (image.Image,IError) {
d.r=r
mut err:=d.read_full(d.tmp[..2])
if err != unsafe { nil }{
return unsafe { nil }, err
}
if d.tmp[0] != 0xff || d.tmp[1] != soi_marker{
return unsafe { nil }, format_error('missing SOI marker')
}
for {
mut err_1:=d.read_full(d.tmp[..2])
if err_1 != unsafe { nil }{
return unsafe { nil }, err_1
}
for d.tmp[0] != 0xff{
d.tmp[0]=d.tmp[1]
d.tmp[1], err=d.read_byte()
if err_1 != unsafe { nil }{
return unsafe { nil }, err_1
}
}
mut marker:=d.tmp[1]
if marker == 0{
continue
}
for marker == 0xff{
marker, err=d.read_byte()
if err_1 != unsafe { nil }{
return unsafe { nil }, err_1
}
}
if marker == eoi_marker{
break
}
if rst0_marker <= marker && marker <= rst7_marker{
continue
}
err=d.read_full(d.tmp[..2])
if err_1 != unsafe { nil }{
return unsafe { nil }, err_1
}
mut n:=isize(d.tmp[0]) << 8 + isize(d.tmp[1]) - 2
if n < 0{
return unsafe { nil }, format_error('short segment length')
}
match marker{
sof0_marker,sof1_marker,sof2_marker{
d.baseline=marker == sof0_marker
d.progressive=marker == sof2_marker
err=d.process_sof(n)
if config_only && d.jfif{
return unsafe { nil }, err_1
}
}
dht_marker{
if config_only{
err=d.ignore(n)
}
else
{
err=d.process_dht(n)
}
}
dqt_marker{
if config_only{
err=d.ignore(n)
}
else
{
err=d.process_dqt(n)
}
}
sos_marker{
if config_only{
return unsafe { nil }, unsafe { nil }
}
err=d.process_sos(n)
}
dri_marker{
if config_only{
err=d.ignore(n)
}
else
{
err=d.process_dri(n)
}
}
app0_marker{
err=d.process_app0_marker(n)
}
app14_marker{
err=d.process_app14_marker(n)
}
else {
if app0_marker <= marker && marker <= app15_marker || marker == com_marker{
err=d.ignore(n)
}
else
if marker < 0xc0{
err=format_error('unknown marker')
}
else
{
err=unsupported_error('unknown marker')
}
}
}
if err_1 != unsafe { nil }{
return unsafe { nil }, err_1
}
}
if d.progressive{
mut err_2:=d.reconstruct_progressive_image()
if err_2 != unsafe { nil }{
return unsafe { nil }, err_2
}
}
if d.img1 != unsafe { nil }{
return d.img1, unsafe { nil }
}
if d.img3 != unsafe { nil }{
if d.black_pix != unsafe { nil }{
return d.apply_black()
}
else
if d.is_rgb(){
return d.convert_to_rgb()
}
return d.img3, unsafe { nil }
}
return unsafe { nil }, format_error('missing SOS marker')
}

// applyBlack combines d.img3 and d.blackPix into a CMYK image. The formula
// used depends on whether the JPEG image is stored as CMYK or YCbCrK,
// indicated by the APP14 (Adobe) metadata.
//
// Adobe CMYK JPEG images are inverted, where 255 means no ink instead of full
// ink, so we apply "v = 255 - v" at various points. Note that a double
// inversion is a no-op, so inversions might be implicit in the code below.
fn (mut d Decoder) apply_black() (image.Image,IError) {
if !d.adobe_transform_valid{
return unsafe { nil }, unsupported_error("unknown color model: 4-component JPEG doesn't have Adobe APP14 metadata")
}
if d.adobe_transform != adobe_transform_unknown{
mut bounds:=d.img3.bounds()
mut img:=image.new_rgba(bounds)
imageutil.draw_yc_b_cr(img, bounds, d.img3, bounds.min)
for i_base, y:=isize(0), bounds.min.y
; y < bounds.max.y; i_base, y=i_base + img.stride, y+1
{
for i, x:=i_base+3, bounds.min.x
; x < bounds.max.x; i, x=i+4, x+1
{
img.pix[i]=255 - d.black_pix[(y - bounds.min.y) * d.black_stride + (x - bounds.min.x)]
}
}
return &image.CMYK{
	pix: img.pix
	stride: img.stride
	rect: img.rect
}, unsafe { nil }
}
mut bounds_1:=d.img3.bounds()
mut img_1:=image.new_cmyk(bounds_1)
mut translations:=[Go2VInlineStruct{d.img3.Y, d.img3.ys_tride},Go2VInlineStruct{d.img3.Cb, d.img3.cs_tride},Go2VInlineStruct{d.img3.Cr, d.img3.cs_tride},Go2VInlineStruct{d.BlackPix, d.black_stride}]!
for t, translation in translations {
mut subsample:=d.comp[t].h != d.comp[0].h || d.comp[t].v != d.comp[0].v
for i_base, y:=isize(0), bounds_1.min.y
; y < bounds_1.max.y; i_base, y=i_base + img_1.stride, y+1
{
mut sy:=y - bounds_1.min.y
if subsample{
sy/=2
}
for i, x:=i_base + t, bounds_1.min.x
; x < bounds_1.max.x; i, x=i+4, x+1
{
mut sx:=x - bounds_1.min.x
if subsample{
sx/=2
}
img_1.pix[i]=255 - translation.src[sy * translation.stride + sx]
}
}
}
return img_1, unsafe { nil }
}

fn (mut d Decoder) is_rgb() bool {
if d.jfif{
return false
}
if d.adobe_transform_valid && d.adobe_transform == adobe_transform_unknown{
return true
}
return d.comp[0].c == `R` && d.comp[1].c == `G` && d.comp[2].c == `B`
}

fn (mut d Decoder) convert_to_rgb() (image.Image,IError) {
mut c_scale:=d.comp[0].h / d.comp[1].h
mut bounds:=d.img3.bounds()
mut img:=image.new_rgba(bounds)
for y:=bounds.min.y
; y < bounds.max.y; y++
{
mut po:=img.pix_offset(bounds.min.x, y)
mut yo:=d.img3.yo_ffset(bounds.min.x, y)
mut co:=d.img3.co_ffset(bounds.min.x, y)
for i, i_max:=isize(0), bounds.max.x - bounds.min.x
; i < i_max; i++
{
img.pix[po + 4 * i+0]=d.img3.y[yo + i]
img.pix[po + 4 * i+1]=d.img3.cb[co + i / c_scale]
img.pix[po + 4 * i+2]=d.img3.cr[co + i / c_scale]
img.pix[po + 4 * i+3]=255
}
}
return img, unsafe { nil }
}

// Decode reads a JPEG image from r and returns it as an [image.Image].
pub fn decode_1(r io.Reader) (image.Image,IError) {
mut d := Decoder{}

return d.decode(r, false)
}

// DecodeConfig returns the color model and dimensions of a JPEG image without
// decoding the entire image.
pub fn decode_config(r io.Reader) (image.Config,IError) {
mut d := Decoder{}

_, err:=d.decode(r, true)
if err != unsafe { nil }{
go2v_tmp_0 := image.Config{}
return go2v_tmp_0, err
}
match d.n_comp{
1{
go2v_tmp_1 := image.Config{
	color_model: color.gray_model
	width: d.width
	height: d.height
}
return go2v_tmp_1, unsafe { nil }
}
3{
mut cm:=color.yc_b_cr_model
if d.is_rgb(){
cm=color.rgbam_odel
}
go2v_tmp_2 := image.Config{
	color_model: cm
	width: d.width
	height: d.height
}
return go2v_tmp_2, unsafe { nil }
}
4{
go2v_tmp_3 := image.Config{
	color_model: color.cmykm_odel
	width: d.width
	height: d.height
}
return go2v_tmp_3, unsafe { nil }
}
}
go2v_tmp_4 := image.Config{}
return go2v_tmp_4, format_error('missing SOF marker')
}

fn init() {
image.register_format('jpeg', "\xff\xd8", decode, decode_config)
}

pub struct Go2VInlineStruct {
mut:
	src []u8
	stride isize
}
