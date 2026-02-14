module jpeg

import image
import image.color
import io

// div returns a/b rounded to the nearest integer, instead of rounded to zero.
fn div(a i32,b i32) i32 {
if a >= 0{
return (a + (b >> 1)) / b
}
return -((-a + (b >> 1)) / b)
}
// bitCount counts the number of bits needed to hold an integer.
__global bit_count = [u8(0),1,2,2,3,3,3,3,4,4,4,4,4,4,4,4,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8]!
enum quantIndex {
quant_index_luminance
quant_index_chrominance
n_quant_index
}
// unscaledQuant are the unscaled quantization tables in zig-zag order. Each
// encoder copies and scales the tables according to its quality parameter.
// The values are derived from section K.1 of the spec, after converting from
// natural to zig-zag order.
__global unscaled_quant = [[u8(16), 11, 12, 14, 12, 10, 16, 14, 13, 14, 18, 17, 16, 19, 24, 40, 26, 24, 22, 22, 24, 49, 35, 37, 29, 40, 58, 51, 61, 60, 57, 51, 56, 55, 64, 72, 92, 78, 64, 68, 87, 69, 55, 56, 80, 109, 81, 87, 95, 98, 103, 104, 103, 62, 77, 113, 121, 112, 100, 120, 92, 101, 103, 99],[u8(17), 18, 18, 24, 21, 24, 47, 26, 26, 47, 99, 66, 56, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99]]!
enum huffIndex {
huff_index_luminance_dc
huff_index_luminance_ac
huff_index_chrominance_dc
huff_index_chrominance_ac
n_huff_index
}
// huffmanSpec specifies a Huffman encoding.
struct HuffmanSpec {
pub mut:
// count[i] is the number of codes of length i+1 bits.
	count [16]u8
// value[i] is the decoded value of the i'th codeword.
	value []u8
}

// theHuffmanSpec is the Huffman encoding specifications.
//
// This encoder uses the same Huffman encoding for all images. It is also the
// same Huffman encoding used by section K.3 of the spec.
//
// The DC tables have 12 decoded values, called categories.
//
// The AC tables have 162 decoded values: bytes that pack a 4-bit Run and a
// 4-bit Size. There are 16 valid Runs and 10 valid Sizes, plus two special R|S
// cases: 0|0 (meaning EOB) and F|0 (meaning ZRL).
__global the_huffman_spec = [HuffmanSpec{[u8(0),1,5,1,1,1,1,1,1,0,0,0,0,0,0,0]!, [u8(0),1,2,3,4,5,6,7,8,9,10,11]},HuffmanSpec{[u8(0),2,1,3,3,2,4,3,5,5,4,4,0,0,1,125]!, [u8(0x01),0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa]},HuffmanSpec{[u8(0),3,1,1,1,1,1,1,1,1,1,0,0,0,0,0]!, [u8(0),1,2,3,4,5,6,7,8,9,10,11]},HuffmanSpec{[u8(0),2,1,2,4,4,3,4,7,5,4,4,0,1,2,119]!, [u8(0x00),0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa]}]!
// huffmanLUT is a compiled look-up table representation of a huffmanSpec.
// Each value maps to a uint32 of which the 8 most significant bits hold the
// codeword size in bits and the 24 least significant bits hold the codeword.
// The maximum codeword size is 16 bits.
type HuffmanLUT = []u32

fn (mut h HuffmanLUT) init(s HuffmanSpec) {
mut max_value:=isize(0)
for _, v in s.value {
if isize(v) > max_value{
max_value=isize(v)
}
}
unsafe { *h=[]u32{len: max_value+1} }
mut code, k:=u32(0), isize(0)
for i:=isize(0)
; i < s.count.len; i++
{
mut n_bits:=u32(i+1) << 24
for j:=u8(0)
; j < s.count[i]; j++
{
(*h)[s.value[k]]=n_bits | code
code++
k++
}
code<<=1
}
}
// theHuffmanLUT are compiled representations of theHuffmanSpec.
__global the_huffman_lut [4]HuffmanLUT

fn init_1() {
for i, s in the_huffman_spec {
the_huffman_lut[i].init(s)
}
}
// writer is a buffered writer.
interface writer {
	flush() IError
}

// encoder encodes an image to the JPEG format.
struct Encoder {
pub mut:
// w is the writer to write to. err is the first error encountered during
// writing. All attempted writes after the first error become no-ops.
	w Writer
	err IError
// buf is a scratch buffer.
	buf [16]u8
// bits and nBits are accumulated bits to write to w.
	bits u32
	n_bits u32
// quant is the scaled quantization tables, in zig-zag order.
	quant [NQuantIndex][BlockSize]u8
}


fn (mut e Encoder) flush() {
if e.err != unsafe { nil }{
return 
}
e.err=e.w.flush()
}

fn (mut e Encoder) write(p []u8) {
if e.err != unsafe { nil }{
return 
}
_, e.err=e.w.write(p)
}

fn (mut e Encoder) write_byte(b u8) {
if e.err != unsafe { nil }{
return 
}
e.err=e.w.write_byte(b)
}

// emit emits the least significant nBits bits of bits to the bit-stream.
// The precondition is bits < 1<<nBits && nBits <= 16.
fn (mut e Encoder) emit(bits u32,n_bits u32) {
n_bits+=e.n_bits
bits<<=32 - n_bits
bits|=e.bits
for n_bits >= 8{
mut b:=u8(bits >> 24)
e.write_byte(b)
if b == 0xff{
e.write_byte(0x00)
}
bits<<=8
n_bits-=8
}
e.bits, e.n_bits=bits, n_bits
}

// emitHuff emits the given value with the given Huffman encoder.
fn (mut e Encoder) emit_huff(h HuffIndex,value i32) {
mut x:=the_huffman_lut[h][value]
e.emit(x & (1 << 24 - 1), x >> 24)
}

// emitHuffRLE emits a run of runLength copies of value encoded with the given
// Huffman encoder.
fn (mut e Encoder) emit_huff_rle(h HuffIndex,run_length i32,value i32) {
mut a, b:=value, value
if a < 0{
a, b=-value, value - 1
}
mut n_bits := 0

if a < 0x100{
n_bits=u32(bit_count[a])
}
else
{
n_bits=8+u32(bit_count[a >> 8])
}
e.emit_huff(h, run_length << 4 | i32(n_bits))
if n_bits > 0{
e.emit(u32(b) & (1 << n_bits - 1), n_bits)
}
}

// writeMarkerHeader writes the header for a marker with the given length.
fn (mut e Encoder) write_marker_header(marker u8,markerlen isize) {
e.buf[0]=0xff
e.buf[1]=marker
e.buf[2]=u8(markerlen >> 8)
e.buf[3]=u8(markerlen & 0xff)
e.write(e.buf[..4])
}

// writeDQT writes the Define Quantization Table marker.
fn (mut e Encoder) write_dqt() {

e.write_marker_header(dqt_marker, markerlen)
for i,  _  in e.quant {
e.write_byte(u8(i))
e.write(e.quant[i][..])
}
}

// writeSOF0 writes the Start Of Frame (Baseline Sequential) marker.
fn (mut e Encoder) write_sof_0(size image.Point,n_component isize) {
mut markerlen:=8+3 * n_component
e.write_marker_header(sof0_marker, markerlen)
e.buf[0]=8
e.buf[1]=u8(size.y >> 8)
e.buf[2]=u8(size.y & 0xff)
e.buf[3]=u8(size.x >> 8)
e.buf[4]=u8(size.x & 0xff)
e.buf[5]=u8(n_component)
if n_component == 1{
e.buf[6]=1
e.buf[7]=0x11
e.buf[8]=0x00
}
else
{
for i:=isize(0)
; i < n_component; i++
{
e.buf[3 * i+6]=u8(i+1)
e.buf[3 * i+7]="\x22\x11\x11"[i]
e.buf[3 * i+8]="\x00\x01\x01"[i]
}
}
e.write(e.buf[..3 * (n_component - 1)+9])
}

// writeDHT writes the Define Huffman Table marker.
fn (mut e Encoder) write_dht(n_component isize) {
mut markerlen:=isize(2)
mut specs:=the_huffman_spec[..]
if n_component == 1{
specs=specs[..2]
}
for _, s in specs {
markerlen+=1+16 + s.value.len
}
e.write_marker_header(dht_marker, markerlen)
for i, s_1 in specs {
e.write_byte("\x00\x10\x01\x11"[i])
e.write(s_1.count[..])
e.write(s_1.value)
}
}

// writeBlock writes a block of pixel data using the given quantization table,
// returning the post-quantized DC value of the DCT-transformed block. b is in
// natural (not zig-zag) order.
fn (mut e Encoder) write_block(b &Block,q QuantIndex,prev_dc i32) i32 {
fdct(b)
mut dc:=div(b[0], 8 * i32(e.quant[q][0]))
e.emit_huff_rle(huff_index(2 * q+0), 0, dc - prev_dc)
mut h, run_length:=huff_index(2 * q+1), i32(0)
for zig:=isize(1)
; zig < block_size; zig++
{
mut ac:=div(b[unzig[zig]], 8 * i32(e.quant[q][zig]))
if ac == 0{
run_length++
}
else
{
for run_length > 15{
e.emit_huff(h, 0xf0)
run_length-=16
}
e.emit_huff_rle(h, run_length, ac)
run_length=0
}
}
if run_length > 0{
e.emit_huff(h, 0x00)
}
return dc
}

// toYCbCr converts the 8x8 region of m whose top-left corner is p to its
// YCbCr values.
fn to_yc_b_cr(m image.Image,p image.Point,y_block &Block,cb_block &Block,cr_block &Block) {
mut b:=m.bounds()
mut xmax:=b.max.x - 1
mut ymax:=b.max.y - 1
for j:=isize(0)
; j < 8; j++
{
for i:=isize(0)
; i < 8; i++
{
mut r, g, b_1, _:=m.at(min(p.x + i, xmax), min(p.y + j, ymax)).rgba()
mut yy, cb, cr:=color.rgbt_o_yc_b_cr(u8(r >> 8), u8(g >> 8), u8(b_1 >> 8))
y_block[8 * j + i]=i32(yy)
cb_block[8 * j + i]=i32(cb)
cr_block[8 * j + i]=i32(cr)
}
}
}

// grayToY stores the 8x8 region of m whose top-left corner is p in yBlock.
fn gray_to_y(m &image.Gray,p image.Point,y_block &Block) {
mut b:=m.bounds()
mut xmax:=b.max.x - 1
mut ymax:=b.max.y - 1
mut pix:=m.pix
for j:=isize(0)
; j < 8; j++
{
for i:=isize(0)
; i < 8; i++
{
mut idx:=m.pix_offset(min(p.x + i, xmax), min(p.y + j, ymax))
y_block[8 * j + i]=i32(pix[idx])
}
}
}

// rgbaToYCbCr is a specialized version of toYCbCr for image.RGBA images.
fn rgba_to_yc_b_cr(m &image.RGBA,p image.Point,y_block &Block,cb_block &Block,cr_block &Block) {
mut b:=m.bounds()
mut xmax:=b.max.x - 1
mut ymax:=b.max.y - 1
for j:=isize(0)
; j < 8; j++
{
mut sj:=p.y + j
if sj > ymax{
sj=ymax
}
mut offset:=(sj - b.min.y) * m.stride - b.min.x * 4
for i:=isize(0)
; i < 8; i++
{
mut sx:=p.x + i
if sx > xmax{
sx=xmax
}
mut pix:=m.pix[offset + sx * 4..]
mut yy, cb, cr:=color.rgbt_o_yc_b_cr(pix[0], pix[1], pix[2])
y_block[8 * j + i]=i32(yy)
cb_block[8 * j + i]=i32(cb)
cr_block[8 * j + i]=i32(cr)
}
}
}

// yCbCrToYCbCr is a specialized version of toYCbCr for image.YCbCr images.
fn y_cb_cr_to_yc_b_cr(m &image.YCbCr,p image.Point,y_block &Block,cb_block &Block,cr_block &Block) {
mut b:=m.bounds()
mut xmax:=b.max.x - 1
mut ymax:=b.max.y - 1
for j:=isize(0)
; j < 8; j++
{
mut sy:=p.y + j
if sy > ymax{
sy=ymax
}
for i:=isize(0)
; i < 8; i++
{
mut sx:=p.x + i
if sx > xmax{
sx=xmax
}
mut yi:=m.yo_ffset(sx, sy)
mut ci:=m.co_ffset(sx, sy)
y_block[8 * j + i]=i32(m.y[yi])
cb_block[8 * j + i]=i32(m.cb[ci])
cr_block[8 * j + i]=i32(m.cr[ci])
}
}
}

// scale scales the 16x16 region represented by the 4 src blocks to the 8x8
// dst block.
fn scale(dst &Block,src [4]Block) {
for i:=isize(0)
; i < 4; i++
{
mut dst_off:=(i & 2) << 4 | (i & 1) << 2
for y:=isize(0)
; y < 4; y++
{
for x:=isize(0)
; x < 4; x++
{
mut j:=16 * y + 2 * x
mut sum:=src[i][j] + src[i][j+1] + src[i][j+8] + src[i][j+9]
dst[8 * y + x + dst_off]=(sum+2) >> 2
}
}
}
}
// sosHeaderY is the SOS marker "\xff\xda" followed by 8 bytes:
//   - the marker length "\x00\x08",
//   - the number of components "\x01",
//   - component 1 uses DC table 0 and AC table 0 "\x01\x00",
//   - the bytes "\x00\x3f\x00". Section B.2.3 of the spec says that for
//     sequential DCTs, those bytes (8-bit Ss, 8-bit Se, 4-bit Ah, 4-bit Al)
//     should be 0x00, 0x3f, 0x00<<4 | 0x00.
__global sos_header_y = [u8(0xff),0xda,0x00,0x08,0x01,0x01,0x00,0x00,0x3f,0x00]
// sosHeaderYCbCr is the SOS marker "\xff\xda" followed by 12 bytes:
//   - the marker length "\x00\x0c",
//   - the number of components "\x03",
//   - component 1 uses DC table 0 and AC table 0 "\x01\x00",
//   - component 2 uses DC table 1 and AC table 1 "\x02\x11",
//   - component 3 uses DC table 1 and AC table 1 "\x03\x11",
//   - the bytes "\x00\x3f\x00". Section B.2.3 of the spec says that for
//     sequential DCTs, those bytes (8-bit Ss, 8-bit Se, 4-bit Ah, 4-bit Al)
//     should be 0x00, 0x3f, 0x00<<4 | 0x00.
__global sos_header_yc_b_cr = [u8(0xff),0xda,0x00,0x0c,0x03,0x01,0x00,0x02,0x11,0x03,0x11,0x00,0x3f,0x00]

// writeSOS writes the StartOfScan marker.
fn (mut e Encoder) write_sos(m image.Image) {
match m.type_name() {
'Gray'{
e.write(sos_header_y)
}
else {
e.write(sos_header_yc_b_cr)
}
}
mut b := Block{}
mut cb,cr := [4]Block{}
mut prev_dcy,prev_dcc_b,prev_dcc_r := 0

mut bounds:=m.bounds()
mut m_1 := m
match m.type_name() {
'Gray'{
for y:=bounds.min.y
; y < bounds.max.y; y+=8
{
for x:=bounds.min.x
; x < bounds.max.x; x+=8
{
mut p:=image.pt(x, y)
gray_to_y(m, p, &b)
prev_dcy=e.write_block(&b, 0, prev_dcy)
}
}
}
else {
mut rgba := m as &image.RGBA
mut ycbcr := m as &image.YCbCr
for y:=bounds.min.y
; y < bounds.max.y; y+=16
{
for x:=bounds.min.x
; x < bounds.max.x; x+=16
{
for i:=isize(0)
; i < 4; i++
{
mut x_off:=(i & 1) * 8
mut y_off:=(i & 2) * 4
mut p_1:=image.pt(x + x_off, y + y_off)
if rgba != unsafe { nil }{
rgba_to_yc_b_cr(rgba, p_1, &b, &cb[i], &cr[i])
}
else
if ycbcr != unsafe { nil }{
y_cb_cr_to_yc_b_cr(ycbcr, p_1, &b, &cb[i], &cr[i])
}
else
{
to_yc_b_cr(m, p_1, &b, &cb[i], &cr[i])
}
prev_dcy=e.write_block(&b, 0, prev_dcy)
}
scale(&b, &cb)
prev_dcc_b=e.write_block(&b, 1, prev_dcc_b)
scale(&b, &cr)
prev_dcc_r=e.write_block(&b, 1, prev_dcc_r)
}
}
}
}
e.emit(0x7f, 7)
}
// DefaultQuality is the default quality encoding parameter.
pub const default_quality = 75
// Options are the encoding parameters.
// Quality ranges from 1 to 100 inclusive, higher is better.
pub struct Options {
pub mut:
	quality isize
}


// Encode writes the Image m to w in JPEG 4:2:0 baseline format with the given
// options. Default parameters are used if a nil *[Options] is passed.
pub fn encode(w io.Writer,m image.Image,o &Options) IError {
mut b:=m.bounds()
if b.dx() >= 1 << 16 || b.dy() >= 1 << 16{
return errors.new('jpeg: image is too large to encode')
}
mut e := Encoder{}

mut ok := w is Writer
mut ww := w as Writer
if ok{
e.w=ww
}
else
{
e.w=bufio.new_writer(w)
}
mut quality:=default_quality
if o != unsafe { nil }{
quality=o.quality
if quality < 1{
quality=1
}
else
if quality > 100{
quality=100
}
}
mut scale := 0

if quality < 50{
scale=5000 / quality
}
else
{
scale=200 - quality * 2
}
for i,  _  in e.quant {
for j,  _  in e.quant[i] {
mut x:=isize(unscaled_quant[i][j])
x=(x * scale+50) / 100
if x < 1{
x=1
}
else
if x > 255{
x=255
}
e.quant[i][j]=u8(x)
}
}
mut n_component:=isize(3)
match m.type_name() {
'Gray'{
n_component=1
}
}
e.buf[0]=0xff
e.buf[1]=0xd8
e.write(e.buf[..2])
e.write_dqt()
e.write_sof_0(b.size(), n_component)
e.write_dht(n_component)
e.write_sos(m)
e.buf[0]=0xff
e.buf[1]=0xd9
e.write(e.buf[..2])
e.flush()
return e.err
}
