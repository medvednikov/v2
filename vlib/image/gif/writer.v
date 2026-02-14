module gif

import compress.lzw
import image
import image.color
import image.color.palette
import image.draw
import internal.byteorder
import io
import math.bits
// Graphic control extension fields.
const gc_label = 0xF9
const gc_block_size = 0x04

fn log2(x isize) isize {
if x < 2{
return 0
}
return bits.len(usize(x - 1)) - 1
}
// writer is a buffered writer.
interface writer {
	flush() IError
}

// encoder encodes an image to the GIF format.
struct Encoder {
pub mut:
// w is the writer to write to. err is the first error encountered during
// writing. All attempted writes after the first error become no-ops.
	w Writer
	err IError
// g is a reference to the data that is being encoded.
	g GIF
// globalCT is the size in bytes of the global color table.
	global_ct isize
// buf is a scratch buffer. It must be at least 256 for the blockWriter.
	buf [256]u8
	global_color_table [3 * 256]u8
	local_color_table [3 * 256]u8
}

// blockWriter writes the block structure of GIF image data, which
// comprises (n, (n bytes)) blocks, with 1 <= n <= 255. It is the
// writer given to the LZW encoder, which is thus immune to the
// blocking.
struct BlockWriter {
pub mut:
	e &Encoder = unsafe { nil }
}


fn (b BlockWriter) setup() {
b.e.buf[0]=0
}

pub fn (b BlockWriter) flush() IError {
return b.e.err
}

pub fn (b BlockWriter) write_byte(c u8) IError {
if b.e.err != unsafe { nil }{
return b.e.err
}
b.e.buf[0]++
b.e.buf[b.e.buf[0]]=c
if b.e.buf[0] < 255{
return unsafe { nil }
}
b.e.write(b.e.buf[..256])
b.e.buf[0]=0
return b.e.err
}

// blockWriter must be an io.Writer for lzw.NewWriter, but this is never
// actually called.
pub fn (b BlockWriter) write(data []u8) (isize,IError) {
for i, c in data {
mut err:=b.write_byte(c)
if err != unsafe { nil }{
return i, err
}
}
return data.len, unsafe { nil }
}

fn (b BlockWriter) close() {
if b.e.buf[0] == 0{
b.e.write_byte(0)
}
else
{
mut n:=usize(b.e.buf[0])
b.e.buf[n+1]=0
b.e.write(b.e.buf[..n+2])
}
b.e.flush()
}

fn (mut e Encoder) flush_1() {
if e.err != unsafe { nil }{
return 
}
e.err=e.w.flush()
}

fn (mut e Encoder) write_1(p []u8) {
if e.err != unsafe { nil }{
return 
}
_, e.err=e.w.write(p)
}

fn (mut e Encoder) write_byte_1(b u8) {
if e.err != unsafe { nil }{
return 
}
e.err=e.w.write_byte(b)
}

fn (mut e Encoder) write_header() {
if e.err != unsafe { nil }{
return 
}
_, e.err=io.write_string(e.w, 'GIF89a')
if e.err != unsafe { nil }{
return 
}
byteorder.lep_ut_uint16(e.buf[0..2], u16(e.g.config.width))
byteorder.lep_ut_uint16(e.buf[2..4], u16(e.g.config.height))
e.write(e.buf[..4])
mut ok := e.g.config.color_model is color.Palette
mut p := e.g.config.color_model as color.Palette
if ok && p.len > 0{
mut padded_size:=log2(p.len)
e.buf[0]=f_color_table | u8(padded_size)
e.buf[1]=e.g.background_index
e.buf[2]=0x00
e.write(e.buf[..3])
mut err := IError{}

e.global_ct, err=encode_color_table(e.global_color_table[..], p, padded_size)
if err != unsafe { nil } && e.err == unsafe { nil }{
e.err=err
return 
}
e.write(e.global_color_table[..e.global_ct])
}
else
{
e.buf[0]=0x00
e.buf[1]=0x00
e.buf[2]=0x00
e.write(e.buf[..3])
}
if e.g.image.len > 1 && e.g.loop_count >= 0{
e.buf[0]=0x21
e.buf[1]=0xff
e.buf[2]=0x0b
e.write(e.buf[..3])
_, err_1:=io.write_string(e.w, 'NETSCAPE2.0')
if err_1 != unsafe { nil } && e.err == unsafe { nil }{
e.err=err_1
return 
}
e.buf[0]=0x03
e.buf[1]=0x01
byteorder.lep_ut_uint16(e.buf[2..4], u16(e.g.loop_count))
e.buf[4]=0x00
e.write(e.buf[..5])
}
}

fn encode_color_table(dst []u8,p color.Palette,size isize) (isize,IError) {
if usize(size) >= 8{
return 0, errors.new('gif: cannot encode color table with more than 256 entries')
}
for i, c in p {
if c == unsafe { nil }{
return 0, errors.new('gif: cannot encode color table with nil entries')
}
mut r,g,b := 0

mut ok := c is color.RGBA
mut rgba := c as color.RGBA
if ok{
r, g, b=rgba.r, rgba.g, rgba.b
}
else
{
mut rr, gg, bb, _:=c.rgba()
r, g, b=u8(rr >> 8), u8(gg >> 8), u8(bb >> 8)
}
dst[3 * i+0]=r
dst[3 * i+1]=g
dst[3 * i+2]=b
}
mut n:=1 << (size+1)
if n > p.len{
clear(dst[3 * p.len..3 * n])
}
return 3 * n, unsafe { nil }
}

fn (mut e Encoder) color_tables_match(local_len isize,transparent_index isize) bool {
mut local_size:=3 * local_len
if transparent_index >= 0{
mut tr_off:=3 * transparent_index
return e.global_color_table[..tr_off] == e.local_color_table[..tr_off] && e.global_color_table[tr_off+3..local_size] == e.local_color_table[tr_off+3..local_size]
}
return e.global_color_table[..local_size] == e.local_color_table[..local_size]
}

fn (mut e Encoder) write_image_block(pm &image.Paletted,delay isize,disposal u8) {
if e.err != unsafe { nil }{
return 
}
if pm.palette.len == 0{
e.err=errors.new('gif: cannot encode image block with empty palette')
return 
}
mut b:=pm.bounds()
if b.min.x < 0 || b.max.x >= 1 << 16 || b.min.y < 0 || b.max.y >= 1 << 16{
e.err=errors.new('gif: image block is too large to encode')
return 
}
if !b.in_(image.Rectangle{
	max: image.Point{
e.g.config.width
e.g.config.height
}
}){
e.err=errors.new('gif: image block is out of bounds')
return 
}
mut transparent_index:=-1
for i, c in pm.palette {
if c == unsafe { nil }{
e.err=errors.new('gif: cannot encode color table with nil entries')
return 
}
_, _, _, a:=c.rgba()
if a == 0{
transparent_index=i
break
}
}
if delay > 0 || disposal != 0 || transparent_index != -1{
e.buf[0]=s_extension
e.buf[1]=gc_label
e.buf[2]=gc_block_size
if transparent_index != -1{
e.buf[3]=0x01 | disposal << 2
}
else
{
e.buf[3]=0x00 | disposal << 2
}
byteorder.lep_ut_uint16(e.buf[4..6], u16(delay))
if transparent_index != -1{
e.buf[6]=u8(transparent_index)
}
else
{
e.buf[6]=0x00
}
e.buf[7]=0x00
e.write(e.buf[..8])
}
e.buf[0]=s_image_descriptor
byteorder.lep_ut_uint16(e.buf[1..3], u16(b.min.x))
byteorder.lep_ut_uint16(e.buf[3..5], u16(b.min.y))
byteorder.lep_ut_uint16(e.buf[5..7], u16(b.dx()))
byteorder.lep_ut_uint16(e.buf[7..9], u16(b.dy()))
e.write(e.buf[..9])
mut padded_size:=log2(pm.palette.len)
mut ok := e.g.config.color_model is color.Palette
mut gp := e.g.config.color_model as color.Palette
if ok && pm.palette.len <= gp.len && &gp[0] == &pm.palette[0]{
e.write_byte(0)
}
else
{
mut ct, err:=encode_color_table(e.local_color_table[..], pm.palette, padded_size)
if err != unsafe { nil }{
if e.err == unsafe { nil }{
e.err=err
}
return 
}
if ct <= e.global_ct && e.color_tables_match(pm.palette.len, transparent_index){
e.write_byte(0)
}
else
{
e.write_byte(f_color_table | u8(padded_size))
e.write(e.local_color_table[..ct])
}
}
mut lit_width:=padded_size+1
if lit_width < 2{
lit_width=2
}
e.write_byte(u8(lit_width))
mut bw:=BlockWriter{
	e: e
}
bw.setup()
mut lzww:=lzw.new_writer(bw, lzw.lsb, lit_width)
mut dx:=b.dx()
if dx == pm.stride{
_, e.err=lzww.write(pm.pix[..dx * b.dy()])
if e.err != unsafe { nil }{
lzww.close()
return 
}
}
else
{
for i_1, y:=isize(0), b.min.y
; y < b.max.y; i, y=i_1 + pm.stride, y+1
{
_, e.err=lzww.write(pm.pix[i_1..i_1 + dx])
if e.err != unsafe { nil }{
lzww.close()
return 
}
}
}
lzww.close()
bw.close()
}
// Options are the encoding parameters.
pub struct Options {
pub mut:
// NumColors is the maximum number of colors used in the image.
// It ranges from 1 to 256.
	num_colors isize
// Quantizer is used to produce a palette with size NumColors.
// palette.Plan9 is used in place of a nil Quantizer.
	quantizer draw.Quantizer
// Drawer is used to convert the source image to the desired palette.
// draw.FloydSteinberg is used in place of a nil Drawer.
	drawer draw.Drawer
}


// EncodeAll writes the images in g to w in GIF format with the
// given loop count and delay between frames.
pub fn encode_all(w io.Writer,g &GIF) IError {
if g.image.len == 0{
return errors.new('gif: must provide at least one image')
}
if g.image.len != g.delay.len{
return errors.new('gif: mismatched image and delay lengths')
}
mut e:=Encoder{
	g: *g
}
if e.g.disposal != unsafe { nil } && e.g.image.len != e.g.disposal.len{
return errors.new('gif: mismatched image and disposal lengths')
}
if e.g.config == (image.Config{}){
mut p:=g.image[0].bounds().max
e.g.config.width=p.x
e.g.config.height=p.y
}
else
if e.g.config.color_model != unsafe { nil }{
mut ok := e.g.config.color_model is color.Palette
if !ok{
return errors.new('gif: GIF color model must be a color.Palette')
}
}
mut ok_1 := w is Writer
mut ww := w as Writer
if ok_1{
e.w=ww
}
else
{
e.w=bufio.new_writer(w)
}
e.write_header()
for i, pm in g.image {
mut disposal:=u8(0)
if g.disposal != unsafe { nil }{
disposal=g.disposal[i]
}
e.write_image_block(pm, g.delay[i], disposal)
}
e.write_byte(s_trailer)
e.flush()
return e.err
}

// Encode writes the Image m to w in GIF format.
pub fn encode(w io.Writer,m image.Image,o &Options) IError {
mut b:=m.bounds()
if b.dx() >= 1 << 16 || b.dy() >= 1 << 16{
return errors.new('gif: image is too large to encode')
}
mut opts:=Options{}
if o != unsafe { nil }{
opts=*o
}
if opts.num_colors < 1 || 256 < opts.num_colors{
opts.num_colors=256
}
if opts.drawer == unsafe { nil }{
opts.drawer=draw.floyd_steinberg
}
mut pm := m as &image.Paletted
if pm == unsafe { nil }{
mut ok := m.color_model() is color.Palette
mut cp := m.color_model() as color.Palette
if ok{
pm=image.new_paletted(b, cp)
for y:=b.min.y
; y < b.max.y; y++
{
for x:=b.min.x
; x < b.max.x; x++
{
pm.set(x, y, cp.convert(m.at(x, y)))
}
}
}
}
if pm == unsafe { nil } || pm.palette.len > opts.num_colors{
pm=image.new_paletted(b, palette.plan9[..opts.num_colors])
if opts.quantizer != unsafe { nil }{
pm.palette=opts.quantizer.quantize(color.Palette{}, m)
}
opts.drawer.draw(pm, b, m, b.min)
}
if pm.rect.min != (image.Point{}){
mut dup:=*pm
dup.rect=dup.rect.sub(dup.rect.min)
pm=&dup
}
return encode_all(w, &GIF{
	image: [pm]
	delay: [isize(0)]
	config: image.Config{
	color_model: pm.palette
	width: b.dx()
	height: b.dy()
}
})
}
