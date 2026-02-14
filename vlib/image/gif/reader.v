module gif

import compress.lzw
import image
import image.color
import io
__global err_not_enough = errors.new('gif: not enough image data')
__global err_too_much = errors.new('gif: too much image data')
__global err_bad_pixel = errors.new('gif: invalid pixel value')
// If the io.Reader does not also have ReadByte, then decode will introduce its own buffering.
interface reader {
}

// Masks etc.
const f_color_table = 1 << 7
const f_interlace = 1 << 6
const f_color_table_bits_mask = 7
const gc_transparent_color_set = 1 << 0
const gc_disposal_method_mask = 7 << 2
// Disposal Methods.
pub const disposal_none = 0x01
pub const disposal_background = 0x02
pub const disposal_previous = 0x03
// Section indicators.
const s_extension = 0x21
const s_image_descriptor = 0x2C
const s_trailer = 0x3B
// Extensions.
const e_text = 0x01
const e_graphic_control = 0xF9
const e_comment = 0xFE
const e_application = 0xFF

fn read_full(r io.Reader,b []u8) IError {
_, err:=io.read_full(r, b)
if err == io.eof{
err=io.err_unexpected_eof
}
return err
}

fn read_byte(r io.ByteReader) (u8,IError) {
mut b, err:=r.read_byte()
if err == io.eof{
err=io.err_unexpected_eof
}
return b, err
}
// decoder is the type used to decode a GIF file.
struct Decoder {
pub mut:
	r Reader
// From header.
	vers string
	width isize
	height isize
	loop_count isize
	delay_time isize
	background_index u8
	disposal_method u8
// From image descriptor.
	image_fields u8
// From graphics control.
	transparent_index u8
	has_transparent_index bool
// Computed.
	global_color_table color.Palette
// Used when decoding.
	delay []isize
	disposal []u8
	image []&image.Paletted
	tmp [1024]u8
}

// blockReader parses the block structure of GIF image data, which comprises
// (n, (n bytes)) blocks, with 1 <= n <= 255. It is the reader given to the
// LZW decoder, which is thus immune to the blocking. After the LZW decoder
// completes, there will be a 0-byte block remaining (0, ()), which is
// consumed when checking that the blockReader is exhausted.
//
// To avoid the allocation of a bufio.Reader for the lzw Reader, blockReader
// implements io.ByteReader and buffers blocks into the decoder's "tmp" buffer.
struct BlockReader {
pub mut:
	d &Decoder = unsafe { nil }
	i u8
	j u8
	err IError
}


fn (mut b BlockReader) fill() {
if b.err != unsafe { nil }{
return 
}
b.j, b.err=read_byte(b.d.r)
if b.j == 0 && b.err == unsafe { nil }{
b.err=io.eof
}
if b.err != unsafe { nil }{
return 
}
b.i=0
b.err=read_full(b.d.r, b.d.tmp[..b.j])
if b.err != unsafe { nil }{
b.j=0
}
}

pub fn (mut b BlockReader) read_byte_1() (u8,IError) {
if b.i == b.j{
b.fill()
if b.err != unsafe { nil }{
return 0, b.err
}
}
mut c:=b.d.tmp[b.i]
b.i++
return c, unsafe { nil }
}

// blockReader must implement io.Reader, but its Read shouldn't ever actually
// be called in practice. The compress/lzw package will only call [blockReader.ReadByte].
pub fn (mut b BlockReader) read(p []u8) (isize,IError) {
if p.len == 0 || b.err != unsafe { nil }{
return 0, b.err
}
if b.i == b.j{
b.fill()
if b.err != unsafe { nil }{
return 0, b.err
}
}
mut n:=copy(p, b.d.tmp[b.i..b.j])
b.i+=u8(n)
return n, unsafe { nil }
}

// close primarily detects whether or not a block terminator was encountered
// after reading a sequence of data sub-blocks. It allows at most one trailing
// sub-block worth of data. I.e., if some number of bytes exist in one sub-block
// following the end of LZW data, the very next sub-block must be the block
// terminator. If the very end of LZW data happened to fill one sub-block, at
// most one more sub-block of length 1 may exist before the block-terminator.
// These accommodations allow us to support GIFs created by less strict encoders.
// See https://golang.org/issue/16146.
fn (mut b BlockReader) close() IError {
if b.err == io.eof{
return unsafe { nil }
}
else
if b.err != unsafe { nil }{
return b.err
}
if b.i == b.j{
b.fill()
if b.err == io.eof{
return unsafe { nil }
}
else
if b.err != unsafe { nil }{
return b.err
}
else
if b.j > 1{
return err_too_much
}
}
b.fill()
if b.err == io.eof{
return unsafe { nil }
}
else
if b.err != unsafe { nil }{
return b.err
}
return err_too_much
}

// decode reads a GIF image from r and stores the result in d.
fn (mut d Decoder) decode(r io.Reader,config_only bool,keep_all_frames bool) IError {
mut ok := r is Reader
mut rr := r as Reader
if ok{
d.r=rr
}
else
{
d.r=bufio.new_reader(r)
}
d.loop_count=-1
mut err:=d.read_header_and_screen_descriptor()
if err != unsafe { nil }{
return err
}
if config_only{
return unsafe { nil }
}
for {
mut c, err_1:=read_byte(d.r)
if err_1 != unsafe { nil }{
return error('')
}
match c{
s_extension{
err=d.read_extension()
if err_1 != unsafe { nil }{
return err_1
}
}
s_image_descriptor{
err=d.read_image_descriptor(keep_all_frames)
if err_1 != unsafe { nil }{
return err_1
}
if !keep_all_frames && d.image.len == 1{
return unsafe { nil }
}
}
s_trailer{
if d.image.len == 0{
return error('')
}
return unsafe { nil }
}
else {
return error('')
}
}
}
}

fn (mut d Decoder) read_header_and_screen_descriptor() IError {
mut err:=read_full(d.r, d.tmp[..13])
if err != unsafe { nil }{
return error('')
}
d.vers=d.tmp[..6].str()

if d.vers != 'GIF87a' && d.vers != 'GIF89a'{
return error('')
}
d.width=isize(d.tmp[6]) + isize(d.tmp[7]) << 8
d.height=isize(d.tmp[8]) + isize(d.tmp[9]) << 8
mut fields:=d.tmp[10]
if fields & f_color_table != 0{
d.background_index=d.tmp[11]
d.global_color_table, err=d.read_color_table(fields)
if err != unsafe { nil }{
return err
}
}
return unsafe { nil }
}

fn (mut d Decoder) read_color_table(fields u8) (color.Palette,IError) {
mut n:=1 << (1+usize(fields & f_color_table_bits_mask))
mut err:=read_full(d.r, d.tmp[..3 * n])
if err != unsafe { nil }{
return unsafe { nil }, error('')
}
mut j, p:=isize(0), color.Palette{}
for i,  _  in p {
p[i]=color.RGBA{
d.tmp[j+0]
d.tmp[j+1]
d.tmp[j+2]
0xFF
}
j+=3
}
return p, unsafe { nil }
}

fn (mut d Decoder) read_extension() IError {
mut extension, err:=read_byte(d.r)
if err != unsafe { nil }{
return error('')
}
mut size:=isize(0)
match extension{
e_text{
size=13
}
e_graphic_control{
return d.read_graphic_control()
}
e_comment{
}
e_application{
mut b, err_1:=read_byte(d.r)
if err_1 != unsafe { nil }{
return error('')
}
size=isize(b)
}
else {
return error('')
}
}
if size > 0{
mut err_2:=read_full(d.r, d.tmp[..size])
if err_2 != unsafe { nil }{
return error('')
}
}
if extension == e_application && d.tmp[..size].str()
 == 'NETSCAPE2.0'{
mut n, err_3:=d.read_block()
if err_3 != unsafe { nil }{
return error('')
}
if n == 0{
return unsafe { nil }
}
if n == 3 && d.tmp[0] == 1{
d.loop_count=isize(d.tmp[1]) | isize(d.tmp[2]) << 8
}
}
for {
mut n_1, err_4:=d.read_block()
if err_4 != unsafe { nil }{
return error('')
}
if n_1 == 0{
return unsafe { nil }
}
}
}

fn (mut d Decoder) read_graphic_control() IError {
mut err:=read_full(d.r, d.tmp[..6])
if err != unsafe { nil }{
return error('')
}
if d.tmp[0] != 4{
return error('')
}
mut flags:=d.tmp[1]
d.disposal_method=(flags & gc_disposal_method_mask) >> 2
d.delay_time=isize(d.tmp[2]) | isize(d.tmp[3]) << 8
if flags & gc_transparent_color_set != 0{
d.transparent_index=d.tmp[4]
d.has_transparent_index=true
}
if d.tmp[5] != 0{
return error('')
}
return unsafe { nil }
}

fn (mut d Decoder) read_image_descriptor(keep_all_frames bool) IError {
mut m, err:=d.new_image_from_descriptor()
if err != unsafe { nil }{
return err
}
mut use_local_color_table:=d.image_fields & f_color_table != 0
if use_local_color_table{
m.palette, err=d.read_color_table(d.image_fields)
if err != unsafe { nil }{
return err
}
}
else
{
if d.global_color_table == unsafe { nil }{
return errors.new('gif: no color table')
}
m.palette=d.global_color_table
}
if d.has_transparent_index{
if !use_local_color_table{
m.palette << d.global_color_table
}
mut ti:=isize(d.transparent_index)
if ti < m.palette.len{
m.palette[ti]=color.RGBA{}
}
else
{
mut p:=color.Palette{}
copy(p, m.palette)
for i:=m.palette.len
; i < p.len; i++
{
p[i]=color.RGBA{}
}
m.palette=p
}
}
mut lit_width, err_1:=read_byte(d.r)
if err_1 != unsafe { nil }{
return error('')
}
if lit_width < 2 || lit_width > 8{
return error('')
}
mut br:=&BlockReader{
	d: d
}
mut lzwr:=lzw.new_reader(br, lzw.lsb, isize(lit_width))
defer {
lzwr.close()
}
err=read_full(lzwr, m.pix)
if err_1 != unsafe { nil }{
if err_1 != io.err_unexpected_eof{
return error('')
}
return err_not_enough
}
mut n, err_2:=lzwr.read(d.tmp[256..257])
if n != 0 || (err_2 != io.eof && err_2 != io.err_unexpected_eof){
if err_2 != unsafe { nil }{
return error('')
}
return err_too_much
}
mut err_3:=br.close()
if err_3 == err_too_much{
return err_too_much
}
else
if err_3 != unsafe { nil }{
return error('')
}
if m.palette.len < 256{
for _, pixel in m.pix {
if isize(pixel) >= m.palette.len{
return err_bad_pixel
}
}
}
if d.image_fields & f_interlace != 0{
uninterlace(m)
}
if keep_all_frames || d.image.len == 0{
d.image << m
d.delay << d.delay_time
d.disposal << d.disposal_method
}
d.delay_time=0
d.has_transparent_index=false
return unsafe { nil }
}

fn (mut d Decoder) new_image_from_descriptor() (&image.Paletted,IError) {
mut err:=read_full(d.r, d.tmp[..9])
if err != unsafe { nil }{
return unsafe { nil }, error('')
}
mut left:=isize(d.tmp[0]) + isize(d.tmp[1]) << 8
mut top:=isize(d.tmp[2]) + isize(d.tmp[3]) << 8
mut width:=isize(d.tmp[4]) + isize(d.tmp[5]) << 8
mut height:=isize(d.tmp[6]) + isize(d.tmp[7]) << 8
d.image_fields=d.tmp[8]
if left + width > d.width || top + height > d.height{
return unsafe { nil }, errors.new('gif: frame bounds larger than image bounds')
}
return image.new_paletted(image.Rectangle{
	min: image.Point{
left
top
}
	max: image.Point{
left + width
top + height
}
}, unsafe { nil }), unsafe { nil }
}

fn (mut d Decoder) read_block() (isize,IError) {
mut n, err:=read_byte(d.r)
if n == 0 || err != unsafe { nil }{
return 0, err
}
mut err_1:=read_full(d.r, d.tmp[..n])
if err_1 != unsafe { nil }{
return 0, err_1
}
return isize(n), unsafe { nil }
}
// interlaceScan defines the ordering for a pass of the interlace algorithm.
struct InterlaceScan {
pub mut:
	skip isize
	start isize
}

// interlacing represents the set of scans in an interlaced GIF image.
__global interlacing = [InterlaceScan{8, 0},InterlaceScan{8, 4},InterlaceScan{4, 2},InterlaceScan{2, 1}]

// uninterlace rearranges the pixels in m to account for interlaced input.
fn uninterlace(m &image.Paletted) {
mut n_pix := []u8{}

mut dx:=m.bounds().dx()
mut dy:=m.bounds().dy()
n_pix=[]u8{len: dx * dy}
mut offset:=isize(0)
for _, pass in interlacing {
mut n_offset:=pass.start * dx
for y:=pass.start
; y < dy; y+=pass.skip
{
copy(n_pix[n_offset..n_offset + dx], m.pix[offset..offset + dx])
offset+=dx
n_offset+=dx * pass.skip
}
}
m.pix=n_pix
}

// Decode reads a GIF image from r and returns the first embedded
// image as an [image.Image].
pub fn decode_1(r io.Reader) (image.Image,IError) {
mut d := Decoder{}

mut err:=d.decode(r, false, false)
if err != unsafe { nil }{
return unsafe { nil }, err
}
return d.image[0], unsafe { nil }
}
// GIF represents the possibly multiple images stored in a GIF file.
pub struct GIF {
pub mut:
	image []&image.Paletted
	delay []isize
// LoopCount controls the number of times an animation will be
// restarted during display.
// A LoopCount of 0 means to loop forever.
// A LoopCount of -1 means to show each frame only once.
// Otherwise, the animation is looped LoopCount+1 times.
	loop_count isize
// Disposal is the successive disposal methods, one per frame. For
// backwards compatibility, a nil Disposal is valid to pass to EncodeAll,
// and implies that each frame's disposal method is 0 (no disposal
// specified).
	disposal []u8
// Config is the global color table (palette), width and height. A nil or
// empty-color.Palette Config.ColorModel means that each frame has its own
// color table and there is no global color table. Each frame's bounds must
// be within the rectangle defined by the two points (0, 0) and
// (Config.Width, Config.Height).
//
// For backwards compatibility, a zero-valued Config is valid to pass to
// EncodeAll, and implies that the overall GIF's width and height equals
// the first frame's bounds' Rectangle.Max point.
	config image.Config
// BackgroundIndex is the background index in the global color table, for
// use with the DisposalBackground disposal method.
	background_index u8
}


// DecodeAll reads a GIF image from r and returns the sequential frames
// and timing information.
pub fn decode_all(r io.Reader) (&GIF,IError) {
mut d := Decoder{}

mut err:=d.decode(r, false, true)
if err != unsafe { nil }{
return unsafe { nil }, err
}
mut gif:=&GIF{
	image: d.image
	loop_count: d.loop_count
	delay: d.delay
	disposal: d.disposal
	config: image.Config{
	color_model: d.global_color_table
	width: d.width
	height: d.height
}
	background_index: d.background_index
}
return gif, unsafe { nil }
}

// DecodeConfig returns the global color model and dimensions of a GIF image
// without decoding the entire image.
pub fn decode_config(r io.Reader) (image.Config,IError) {
mut d := Decoder{}

mut err:=d.decode(r, true, false)
if err != unsafe { nil }{
go2v_tmp_0 := image.Config{}
return go2v_tmp_0, err
}
go2v_tmp_1 := image.Config{
	color_model: d.global_color_table
	width: d.width
	height: d.height
}
return go2v_tmp_1, unsafe { nil }
}

fn init() {
image.register_format('gif', 'GIF8?a', decode, decode_config)
}
