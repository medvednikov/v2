module draw

import image
import image.color
import image.internal.imageutil
// m is the maximum color value returned by image.Color.RGBA.
const m = 1 << 16 - 1
// Image is an image.Image with a Set method to change a single pixel.
pub interface Image {
	set(x isize,y isize,c color.Color)
}

// RGBA64Image extends both the [Image] and [image.RGBA64Image] interfaces with a
// SetRGBA64 method to change a single pixel. SetRGBA64 is equivalent to
// calling Set, but it can avoid allocations from converting concrete color
// types to the [color.Color] interface type.
pub interface RGBA64Image {
	set(x isize,y isize,c color.Color)
	set_rgba_64(x isize,y isize,c color.RGBA64)
}

// Quantizer produces a palette for an image.
pub interface Quantizer {
// Quantize appends up to cap(p) - len(p) colors to p and returns the
// updated palette suitable for converting m to a paletted image.
	quantize(p color.Palette,m image.Image) color.Palette
}

// Op is a Porter-Duff compositing operator.
enum Op {
over
src
}

// Draw implements the [Drawer] interface by calling the Draw function with this
// [Op].
pub fn (op Op) draw(dst Image,r image.Rectangle,src image.Image,sp image.Point) {
go2v_tmp_0 := image.Point{}
draw_mask(dst, r, .src, sp, unsafe { nil }, go2v_tmp_0, op)
}
// Drawer contains the [Draw] method.
pub interface Drawer {
// Draw aligns r.Min in dst with sp in src and then replaces the
// rectangle r in dst with the result of drawing src on dst.
	draw(dst Image,r image.Rectangle,src image.Image,sp image.Point)
}

// FloydSteinberg is a [Drawer] that is the [Src] [Op] with Floyd-Steinberg error
// diffusion.
__global floyd_steinberg Drawer
struct FloydSteinberg {
}


pub fn (mut _ FloydSteinberg) draw_1(dst Image,r image.Rectangle,src image.Image,sp image.Point) {
clip(dst, &r, .src, &sp, unsafe { nil }, unsafe { nil })
if r.empty(){
return 
}
draw_paletted(dst, r, .src, sp, true)
}

// clip clips r against each image's bounds (after translating into the
// destination image's coordinate space) and shifts the points sp and mp by
// the same amount as the change in r.Min.
fn clip(dst Image,r image.Rectangle,src image.Image,sp &image.Point,mask image.Image,mp &image.Point) {
mut orig:=r.min
unsafe { *r=r.intersect(dst.bounds()) }
unsafe { *r=r.intersect(.src.bounds().add(orig.sub(*sp))) }
if mask != unsafe { nil }{
unsafe { *r=r.intersect(mask.bounds().add(orig.sub(*mp))) }
}
mut dx:=r.min.x - orig.x
mut dy:=r.min.y - orig.y
if dx == 0 && dy == 0{
return 
}
sp.x+=dx
sp.y+=dy
if mp != unsafe { nil }{
mp.x+=dx
mp.y+=dy
}
}

fn process_backward(dst image.Image,r image.Rectangle,src image.Image,sp image.Point) bool {
return dst == .src && r.overlaps(r.add(sp.sub(r.min))) && (sp.y < r.min.y || (sp.y == r.min.y && sp.x < r.min.x))
}

// Draw calls [DrawMask] with a nil mask.
pub fn draw_2(dst Image,r image.Rectangle,src image.Image,sp image.Point,op Op) {
go2v_tmp_1 := image.Point{}
draw_mask(dst, r, .src, sp, unsafe { nil }, go2v_tmp_1, op)
}

// DrawMask aligns r.Min in dst with sp in src and mp in mask and then replaces the rectangle r
// in dst with the result of a Porter-Duff composition. A nil mask is treated as opaque.
pub fn draw_mask(dst Image,r image.Rectangle,src image.Image,sp image.Point,mask image.Image,mp image.Point,op Op) {
clip(dst, &r, .src, &sp, mask, &mp)
if r.empty(){
return 
}
mut dst0 := dst
match dst.type_name() {
'RGBA'{
if op == .over{
if mask == unsafe { nil }{
mut src0 := .src
match .src.type_name() {
'Uniform'{
mut sr, sg, sb, sa:=src0.rgba()
if sa == 0xffff{
draw_fill_src(dst0, r, sr, sg, sb, sa)
}
else
{
draw_fill_over(dst0, r, sr, sg, sb, sa)
}
return 
}
'RGBA'{
draw_copy_over(dst0, r, src0, sp)
return 
}
'NRGBA'{
draw_nrgbao_ver(dst0, r, src0, sp)
return 
}
'YCbCr'{
if imageutil.draw_yc_b_cr(dst0, r, src0, sp){
return 
}
}
'Gray'{
draw_gray(dst0, r, src0, sp)
return 
}
'CMYK'{
draw_cmyk(dst0, r, src0, sp)
return 
}
}
}
else
{
mut ok := mask is &image.Alpha
mut mask0 := mask as &image.Alpha
if ok{
mut src0_1 := .src
match .src.type_name() {
'Uniform'{
draw_glyph_over(dst0, r, src0, mask0, mp)
return 
}
'RGBA'{
draw_rgbam_ask_over(dst0, r, src0, sp, mask0, mp)
return 
}
'Gray'{
draw_gray_mask_over(dst0, r, src0, sp, mask0, mp)
return 
}
'RGBA64Image'{
draw_rgba_64_image_mask_over(dst0, r, src0, sp, mask0, mp)
return 
}
}
}
}
}
else
{
if mask == unsafe { nil }{
mut src0_2 := .src
match .src.type_name() {
'Uniform'{
mut sr_1, sg_1, sb_1, sa_1:=src0.rgba()
draw_fill_src(dst0, r, sr_1, sg_1, sb_1, sa_1)
return 
}
'RGBA'{
mut d0:=dst0.pix_offset(r.min.x, r.min.y)
mut s0:=src0.pix_offset(sp.x, sp.y)
draw_copy_src(dst0.pix[d0..], dst0.stride, r, src0.pix[s0..], src0.stride, sp, 4 * r.dx())
return 
}
'NRGBA'{
draw_nrgbas_rc(dst0, r, src0, sp)
return 
}
'YCbCr'{
if imageutil.draw_yc_b_cr(dst0, r, src0, sp){
return 
}
}
'Gray'{
draw_gray(dst0, r, src0, sp)
return 
}
'CMYK'{
draw_cmyk(dst0, r, src0, sp)
return 
}
}
}
}
draw_rgba(dst0, r, .src, sp, mask, mp, op)
return 
}
'Paletted'{
if op == .src && mask == unsafe { nil }{
mut ok_1 := .src is &image.Uniform
mut src0_3 := .src as &image.Uniform
if ok_1{
mut color_index:=u8(dst0.palette.index(src0_3.c))
mut i0:=dst0.pix_offset(r.min.x, r.min.y)
mut i1:=i0 + r.dx()
for i:=i0
; i < i1; i++
{
dst0.pix[i]=color_index
}
mut first_row:=dst0.pix[i0..i1]
for y:=r.min.y+1
; y < r.max.y; y++
{
i0+=dst0.stride
i1+=dst0.stride
copy(dst0.pix[i0..i1], first_row)
}
return 
}
else
if !process_backward(dst, r, .src, sp){
draw_paletted(dst0, r, .src, sp, false)
return 
}
}
}
'NRGBA'{
if op == .src && mask == unsafe { nil }{
mut ok_2 := .src is &image.NRGBA
mut src0_4 := .src as &image.NRGBA
if ok_2{
mut d0_1:=dst0.pix_offset(r.min.x, r.min.y)
mut s0_1:=src0_4.pix_offset(sp.x, sp.y)
draw_copy_src(dst0.pix[d0_1..], dst0.stride, r, src0_4.pix[s0_1..], src0_4.stride, sp, 4 * r.dx())
return 
}
}
}
'NRGBA64'{
if op == .src && mask == unsafe { nil }{
mut ok_3 := .src is &image.NRGBA64
mut src0_5 := .src as &image.NRGBA64
if ok_3{
mut d0_2:=dst0.pix_offset(r.min.x, r.min.y)
mut s0_2:=src0_5.pix_offset(sp.x, sp.y)
draw_copy_src(dst0.pix[d0_2..], dst0.stride, r, src0_5.pix[s0_2..], src0_5.stride, sp, 8 * r.dx())
return 
}
}
}
}
mut x0, x1, dx:=r.min.x, r.max.x, isize(1)
mut y0, y1, dy:=r.min.y, r.max.y, isize(1)
if process_backward(dst, r, .src, sp){
x0, x1, dx=x1 - 1, x0 - 1, -1
y0, y1, dy=y1 - 1, y0 - 1, -1
}
mut dst0_1 := dst as RGBA64Image
if dst0_1 != unsafe { nil }{
mut src0_6 := .src as image.RGBA64Image
if src0_6 != unsafe { nil }{
if mask == unsafe { nil }{
mut sy:=sp.y + y0 - r.min.y
mut my:=mp.y + y0 - r.min.y
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
mut sx:=sp.x + x0 - r.min.x
mut mx:=mp.x + x0 - r.min.x
for x:=x0
; x != x1; x, sx, mx=x + dx, sx + dx, mx + dx
{
if op == .src{
dst0_1.set_rgba_64(x, y, src0_6.rgba_64_at(sx, sy))
}
else
{
mut srgba:=src0_6.rgba_64_at(sx, sy)
mut a:=m - u32(srgba.a)
mut drgba:=dst0_1.rgba_64_at(x, y)
go2v_tmp_2 := color.RGBA64{
	r: u16((u32(drgba.r) * a) / m) + srgba.r
	g: u16((u32(drgba.g) * a) / m) + srgba.g
	b: u16((u32(drgba.b) * a) / m) + srgba.b
	a: u16((u32(drgba.a) * a) / m) + srgba.a
}
dst0_1.set_rgba_64(x, y, go2v_tmp_2)
}
}
}
return 
}
else
{
mut mask0_1 := mask as image.RGBA64Image
if mask0_1 != unsafe { nil }{
mut sy_1:=sp.y + y0 - r.min.y
mut my_1:=mp.y + y0 - r.min.y
for y:=y0
; y != y1; y, sy, my=y + dy, sy_1 + dy, my_1 + dy
{
mut sx_1:=sp.x + x0 - r.min.x
mut mx_1:=mp.x + x0 - r.min.x
for x:=x0
; x != x1; x, sx, mx=x + dx, sx_1 + dx, mx_1 + dx
{
mut ma:=u32(mask0_1.rgba_64_at(mx_1, my_1).a)
if ma == 0{
if op == .over{
}
else
{
go2v_tmp_3 := color.RGBA64{}
dst0_1.set_rgba_64(x, y, go2v_tmp_3)
}
}
else if ma == m && op == .src{
dst0_1.set_rgba_64(x, y, src0_6.rgba_64_at(sx_1, sy_1))
}
else {
mut srgba_1:=src0_6.rgba_64_at(sx_1, sy_1)
if op == .over{
mut drgba_1:=dst0_1.rgba_64_at(x, y)
mut a_1:=m - (u32(srgba_1.a) * ma / m)
go2v_tmp_4 := color.RGBA64{
	r: u16((u32(drgba_1.r) * a_1 + u32(srgba_1.r) * ma) / m)
	g: u16((u32(drgba_1.g) * a_1 + u32(srgba_1.g) * ma) / m)
	b: u16((u32(drgba_1.b) * a_1 + u32(srgba_1.b) * ma) / m)
	a: u16((u32(drgba_1.a) * a_1 + u32(srgba_1.a) * ma) / m)
}
dst0_1.set_rgba_64(x, y, go2v_tmp_4)
}
else
{
go2v_tmp_5 := color.RGBA64{
	r: u16(u32(srgba_1.r) * ma / m)
	g: u16(u32(srgba_1.g) * ma / m)
	b: u16(u32(srgba_1.b) * ma / m)
	a: u16(u32(srgba_1.a) * ma / m)
}
dst0_1.set_rgba_64(x, y, go2v_tmp_5)
}
}
}
}
return 
}
}
}
}
mut out := color.RGBA64{}

mut sy_2:=sp.y + y0 - r.min.y
mut my_2:=mp.y + y0 - r.min.y
for y:=y0
; y != y1; y, sy, my=y + dy, sy_2 + dy, my_2 + dy
{
mut sx_2:=sp.x + x0 - r.min.x
mut mx_2:=mp.x + x0 - r.min.x
for x:=x0
; x != x1; x, sx, mx=x + dx, sx_2 + dx, mx_2 + dx
{
mut ma_1:=u32(m)
if mask != unsafe { nil }{
_, _, _, ma=mask.at(mx_2, my_2).rgba()
}
if ma_1 == 0{
if op == .over{
}
else
{
dst.set(x, y, color.transparent)
}
}
else if ma_1 == m && op == .src{
dst.set(x, y, .src.at(sx_2, sy_2))
}
else {
mut sr_2, sg_2, sb_2, sa_2:=.src.at(sx_2, sy_2).rgba()
if op == .over{
mut dr, dg, db, da:=dst.at(x, y).rgba()
mut a_2:=m - (sa_2 * ma_1 / m)
out.r=u16((dr * a_2 + sr_2 * ma_1) / m)
out.g=u16((dg * a_2 + sg_2 * ma_1) / m)
out.b=u16((db * a_2 + sb_2 * ma_1) / m)
out.a=u16((da * a_2 + sa_2 * ma_1) / m)
}
else
{
out.r=u16(sr_2 * ma_1 / m)
out.g=u16(sg_2 * ma_1 / m)
out.b=u16(sb_2 * ma_1 / m)
out.a=u16(sa_2 * ma_1 / m)
}
dst.set(x, y, &out)
}
}
}
}

fn draw_fill_over(dst &image.RGBA,r image.Rectangle,sr u32,sg u32,sb u32,sa u32) {
mut a:=(m - sa) * 0x101
mut i0:=dst.pix_offset(r.min.x, r.min.y)
mut i1:=i0 + r.dx() * 4
for y:=r.min.y
; y != r.max.y; y++
{
for i:=i0
; i < i1; i+=4
{
mut dr:=&dst.pix[i+0]
mut dg:=&dst.pix[i+1]
mut db:=&dst.pix[i+2]
mut da:=&dst.pix[i+3]
unsafe { *dr=u8((u32(*dr) * a / m + sr) >> 8) }
unsafe { *dg=u8((u32(*dg) * a / m + sg) >> 8) }
unsafe { *db=u8((u32(*db) * a / m + sb) >> 8) }
unsafe { *da=u8((u32(*da) * a / m + sa) >> 8) }
}
i0+=dst.stride
i1+=dst.stride
}
}

fn draw_fill_src(dst &image.RGBA,r image.Rectangle,sr u32,sg u32,sb u32,sa u32) {
mut sr8:=u8(sr >> 8)
mut sg8:=u8(sg >> 8)
mut sb8:=u8(sb >> 8)
mut sa8:=u8(sa >> 8)
mut i0:=dst.pix_offset(r.min.x, r.min.y)
mut i1:=i0 + r.dx() * 4
for i:=i0
; i < i1; i+=4
{
dst.pix[i+0]=sr8
dst.pix[i+1]=sg8
dst.pix[i+2]=sb8
dst.pix[i+3]=sa8
}
mut first_row:=dst.pix[i0..i1]
for y:=r.min.y+1
; y < r.max.y; y++
{
i0+=dst.stride
i1+=dst.stride
copy(dst.pix[i0..i1], first_row)
}
}

fn draw_copy_over(dst &image.RGBA,r image.Rectangle,src &image.RGBA,sp image.Point) {
mut dx, dy:=r.dx(), r.dy()
mut d0:=dst.pix_offset(r.min.x, r.min.y)
mut s0:=.src.pix_offset(sp.x, sp.y)
mut ddelta,sdelta := 0
mut i0,i1,idelta := 0

if r.min.y < sp.y || r.min.y == sp.y && r.min.x <= sp.x{
ddelta=dst.stride
sdelta=.src.stride
i0, i1, idelta=0, dx * 4, 4
}
else
{
d0+=(dy - 1) * dst.stride
s0+=(dy - 1) * .src.stride
ddelta=-dst.stride
sdelta=-.src.stride
i0, i1, idelta=(dx - 1) * 4, -4, -4
}
for ; dy > 0; dy--
{
mut dpix:=dst.pix[d0..]
mut spix:=.src.pix[s0..]
for i:=i0
; i != i1; i+=idelta
{
mut s:=spix[i..i+4]
mut sr:=u32(s[0]) * 0x101
mut sg:=u32(s[1]) * 0x101
mut sb:=u32(s[2]) * 0x101
mut sa:=u32(s[3]) * 0x101
mut a:=(m - sa) * 0x101
mut d:=dpix[i..i+4]
d[0]=u8((u32(d[0]) * a / m + sr) >> 8)
d[1]=u8((u32(d[1]) * a / m + sg) >> 8)
d[2]=u8((u32(d[2]) * a / m + sb) >> 8)
d[3]=u8((u32(d[3]) * a / m + sa) >> 8)
}
d0+=ddelta
s0+=sdelta
}
}

// drawCopySrc copies bytes to dstPix from srcPix. These arguments roughly
// correspond to the Pix fields of the image package's concrete image.Image
// implementations, but are offset (dstPix is dst.Pix[dpOffset:] not dst.Pix).
fn draw_copy_src(dst_pix []u8,dst_stride isize,r image.Rectangle,src_pix []u8,src_stride isize,sp image.Point,bytes_per_row isize) {
mut d0, s0, ddelta, sdelta, dy:=isize(0), isize(0), dst_stride, src_stride, r.dy()
if r.min.y > sp.y{
d0=(dy - 1) * dst_stride
s0=(dy - 1) * src_stride
ddelta=-dst_stride
sdelta=-src_stride
}
for ; dy > 0; dy--
{
copy(dst_pix[d0..d0 + bytes_per_row], src_pix[s0..s0 + bytes_per_row])
d0+=ddelta
s0+=sdelta
}
}

fn draw_nrgbao_ver(dst &image.RGBA,r image.Rectangle,src &image.NRGBA,sp image.Point) {
mut i0:=(r.min.x - dst.rect.min.x) * 4
mut i1:=(r.max.x - dst.rect.min.x) * 4
mut si0:=(sp.x - .src.rect.min.x) * 4
mut y_max:=r.max.y - dst.rect.min.y
mut y:=r.min.y - dst.rect.min.y
mut sy:=sp.y - .src.rect.min.y
for ; y != y_max; y, sy=y+1, sy+1
{
mut dpix:=dst.pix[y * dst.stride..]
mut spix:=.src.pix[sy * .src.stride..]
for i, si:=i0, si0
; i < i1; i, si=i+4, si+4
{
mut s:=spix[si..si+4]
mut sa:=u32(s[3]) * 0x101
mut sr:=u32(s[0]) * sa / 0xff
mut sg:=u32(s[1]) * sa / 0xff
mut sb:=u32(s[2]) * sa / 0xff
mut d:=dpix[i..i+4]
mut dr:=u32(d[0])
mut dg:=u32(d[1])
mut db:=u32(d[2])
mut da:=u32(d[3])
mut a:=(m - sa) * 0x101
d[0]=u8((dr * a / m + sr) >> 8)
d[1]=u8((dg * a / m + sg) >> 8)
d[2]=u8((db * a / m + sb) >> 8)
d[3]=u8((da * a / m + sa) >> 8)
}
}
}

fn draw_nrgbas_rc(dst &image.RGBA,r image.Rectangle,src &image.NRGBA,sp image.Point) {
mut i0:=(r.min.x - dst.rect.min.x) * 4
mut i1:=(r.max.x - dst.rect.min.x) * 4
mut si0:=(sp.x - .src.rect.min.x) * 4
mut y_max:=r.max.y - dst.rect.min.y
mut y:=r.min.y - dst.rect.min.y
mut sy:=sp.y - .src.rect.min.y
for ; y != y_max; y, sy=y+1, sy+1
{
mut dpix:=dst.pix[y * dst.stride..]
mut spix:=.src.pix[sy * .src.stride..]
for i, si:=i0, si0
; i < i1; i, si=i+4, si+4
{
mut s:=spix[si..si+4]
mut sa:=u32(s[3]) * 0x101
mut sr:=u32(s[0]) * sa / 0xff
mut sg:=u32(s[1]) * sa / 0xff
mut sb:=u32(s[2]) * sa / 0xff
mut d:=dpix[i..i+4]
d[0]=u8(sr >> 8)
d[1]=u8(sg >> 8)
d[2]=u8(sb >> 8)
d[3]=u8(sa >> 8)
}
}
}

fn draw_gray(dst &image.RGBA,r image.Rectangle,src &image.Gray,sp image.Point) {
mut i0:=(r.min.x - dst.rect.min.x) * 4
mut i1:=(r.max.x - dst.rect.min.x) * 4
mut si0:=(sp.x - .src.rect.min.x) * 1
mut y_max:=r.max.y - dst.rect.min.y
mut y:=r.min.y - dst.rect.min.y
mut sy:=sp.y - .src.rect.min.y
for ; y != y_max; y, sy=y+1, sy+1
{
mut dpix:=dst.pix[y * dst.stride..]
mut spix:=.src.pix[sy * .src.stride..]
for i, si:=i0, si0
; i < i1; i, si=i+4, si+1
{
mut p:=spix[si]
mut d:=dpix[i..i+4]
d[0]=p
d[1]=p
d[2]=p
d[3]=255
}
}
}

fn draw_cmyk(dst &image.RGBA,r image.Rectangle,src &image.CMYK,sp image.Point) {
mut i0:=(r.min.x - dst.rect.min.x) * 4
mut i1:=(r.max.x - dst.rect.min.x) * 4
mut si0:=(sp.x - .src.rect.min.x) * 4
mut y_max:=r.max.y - dst.rect.min.y
mut y:=r.min.y - dst.rect.min.y
mut sy:=sp.y - .src.rect.min.y
for ; y != y_max; y, sy=y+1, sy+1
{
mut dpix:=dst.pix[y * dst.stride..]
mut spix:=.src.pix[sy * .src.stride..]
for i, si:=i0, si0
; i < i1; i, si=i+4, si+4
{
mut s:=spix[si..si+4]
mut d:=dpix[i..i+4]
d[0], d[1], d[2]=color.cmykt_o_rgb(s[0], s[1], s[2], s[3])
d[3]=255
}
}
}

fn draw_glyph_over(dst &image.RGBA,r image.Rectangle,src &image.Uniform,mask &image.Alpha,mp image.Point) {
mut i0:=dst.pix_offset(r.min.x, r.min.y)
mut i1:=i0 + r.dx() * 4
mut mi0:=mask.pix_offset(mp.x, mp.y)
mut sr, sg, sb, sa:=.src.rgba()
for y, my:=r.min.y, mp.y
; y != r.max.y; y, my=y+1, my+1
{
for i, mi:=i0, mi0
; i < i1; i, mi=i+4, mi+1
{
mut ma:=u32(mask.pix[mi])
if ma == 0{
continue
}
ma|=ma << 8
mut a:=(m - (sa * ma / m)) * 0x101
mut d:=dst.pix[i..i+4]
d[0]=u8((u32(d[0]) * a + sr * ma) / m >> 8)
d[1]=u8((u32(d[1]) * a + sg * ma) / m >> 8)
d[2]=u8((u32(d[2]) * a + sb * ma) / m >> 8)
d[3]=u8((u32(d[3]) * a + sa * ma) / m >> 8)
}
i0+=dst.stride
i1+=dst.stride
mi0+=mask.stride
}
}

fn draw_gray_mask_over(dst &image.RGBA,r image.Rectangle,src &image.Gray,sp image.Point,mask &image.Alpha,mp image.Point) {
mut x0, x1, dx:=r.min.x, r.max.x, isize(1)
mut y0, y1, dy:=r.min.y, r.max.y, isize(1)
if r.overlaps(r.add(sp.sub(r.min))){
if sp.y < r.min.y || sp.y == r.min.y && sp.x < r.min.x{
x0, x1, dx=x1 - 1, x0 - 1, -1
y0, y1, dy=y1 - 1, y0 - 1, -1
}
}
mut sy:=sp.y + y0 - r.min.y
mut my:=mp.y + y0 - r.min.y
mut sx0:=sp.x + x0 - r.min.x
mut mx0:=mp.x + x0 - r.min.x
mut sx1:=sx0 + (x1 - x0)
mut i0:=dst.pix_offset(x0, y0)
mut di:=dx * 4
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut mi:=mask.pix_offset(mx, my)
mut ma:=u32(mask.pix[mi])
ma|=ma << 8
mut si:=.src.pix_offset(sx, sy)
mut sy_1:=u32(.src.pix[si])
sy|=sy_1 << 8
mut sa:=u32(0xffff)
mut d:=dst.pix[i..i+4]
mut dr:=u32(d[0])
mut dg:=u32(d[1])
mut db:=u32(d[2])
mut da:=u32(d[3])
mut a:=(m - (sa * ma / m)) * 0x101
d[0]=u8((dr * a + sy_1 * ma) / m >> 8)
d[1]=u8((dg * a + sy_1 * ma) / m >> 8)
d[2]=u8((db * a + sy_1 * ma) / m >> 8)
d[3]=u8((da * a + sa * ma) / m >> 8)
}
i0+=dy * dst.stride
}
}

fn draw_rgbam_ask_over(dst &image.RGBA,r image.Rectangle,src &image.RGBA,sp image.Point,mask &image.Alpha,mp image.Point) {
mut x0, x1, dx:=r.min.x, r.max.x, isize(1)
mut y0, y1, dy:=r.min.y, r.max.y, isize(1)
if dst == .src && r.overlaps(r.add(sp.sub(r.min))){
if sp.y < r.min.y || sp.y == r.min.y && sp.x < r.min.x{
x0, x1, dx=x1 - 1, x0 - 1, -1
y0, y1, dy=y1 - 1, y0 - 1, -1
}
}
mut sy:=sp.y + y0 - r.min.y
mut my:=mp.y + y0 - r.min.y
mut sx0:=sp.x + x0 - r.min.x
mut mx0:=mp.x + x0 - r.min.x
mut sx1:=sx0 + (x1 - x0)
mut i0:=dst.pix_offset(x0, y0)
mut di:=dx * 4
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut mi:=mask.pix_offset(mx, my)
mut ma:=u32(mask.pix[mi])
ma|=ma << 8
mut si:=.src.pix_offset(sx, sy)
mut sr:=u32(.src.pix[si+0])
mut sg:=u32(.src.pix[si+1])
mut sb:=u32(.src.pix[si+2])
mut sa:=u32(.src.pix[si+3])
sr|=sr << 8
sg|=sg << 8
sb|=sb << 8
sa|=sa << 8
mut d:=dst.pix[i..i+4]
mut dr:=u32(d[0])
mut dg:=u32(d[1])
mut db:=u32(d[2])
mut da:=u32(d[3])
mut a:=(m - (sa * ma / m)) * 0x101
d[0]=u8((dr * a + sr * ma) / m >> 8)
d[1]=u8((dg * a + sg * ma) / m >> 8)
d[2]=u8((db * a + sb * ma) / m >> 8)
d[3]=u8((da * a + sa * ma) / m >> 8)
}
i0+=dy * dst.stride
}
}

fn draw_rgba_64_image_mask_over(dst &image.RGBA,r image.Rectangle,src image.RGBA64Image,sp image.Point,mask &image.Alpha,mp image.Point) {
mut x0, x1, dx:=r.min.x, r.max.x, isize(1)
mut y0, y1, dy:=r.min.y, r.max.y, isize(1)
if image.image(dst) == .src && r.overlaps(r.add(sp.sub(r.min))){
if sp.y < r.min.y || sp.y == r.min.y && sp.x < r.min.x{
x0, x1, dx=x1 - 1, x0 - 1, -1
y0, y1, dy=y1 - 1, y0 - 1, -1
}
}
mut sy:=sp.y + y0 - r.min.y
mut my:=mp.y + y0 - r.min.y
mut sx0:=sp.x + x0 - r.min.x
mut mx0:=mp.x + x0 - r.min.x
mut sx1:=sx0 + (x1 - x0)
mut i0:=dst.pix_offset(x0, y0)
mut di:=dx * 4
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut mi:=mask.pix_offset(mx, my)
mut ma:=u32(mask.pix[mi])
ma|=ma << 8
mut srgba:=.src.rgba_64_at(sx, sy)
mut d:=dst.pix[i..i+4]
mut dr:=u32(d[0])
mut dg:=u32(d[1])
mut db:=u32(d[2])
mut da:=u32(d[3])
mut a:=(m - (u32(srgba.a) * ma / m)) * 0x101
d[0]=u8((dr * a + u32(srgba.r) * ma) / m >> 8)
d[1]=u8((dg * a + u32(srgba.g) * ma) / m >> 8)
d[2]=u8((db * a + u32(srgba.b) * ma) / m >> 8)
d[3]=u8((da * a + u32(srgba.a) * ma) / m >> 8)
}
i0+=dy * dst.stride
}
}

fn draw_rgba(dst &image.RGBA,r image.Rectangle,src image.Image,sp image.Point,mask image.Image,mp image.Point,op Op) {
mut x0, x1, dx:=r.min.x, r.max.x, isize(1)
mut y0, y1, dy:=r.min.y, r.max.y, isize(1)
if image.image(dst) == .src && r.overlaps(r.add(sp.sub(r.min))){
if sp.y < r.min.y || sp.y == r.min.y && sp.x < r.min.x{
x0, x1, dx=x1 - 1, x0 - 1, -1
y0, y1, dy=y1 - 1, y0 - 1, -1
}
}
mut sy:=sp.y + y0 - r.min.y
mut my:=mp.y + y0 - r.min.y
mut sx0:=sp.x + x0 - r.min.x
mut mx0:=mp.x + x0 - r.min.x
mut sx1:=sx0 + (x1 - x0)
mut i0:=dst.pix_offset(x0, y0)
mut di:=dx * 4
mut src0 := .src as image.RGBA64Image
if src0 != unsafe { nil }{
if mask == unsafe { nil }{
if op == .over{
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut srgba:=src0.rgba_64_at(sx, sy)
mut d:=dst.pix[i..i+4]
mut dr:=u32(d[0])
mut dg:=u32(d[1])
mut db:=u32(d[2])
mut da:=u32(d[3])
mut a:=(m - u32(srgba.a)) * 0x101
d[0]=u8((dr * a / m + u32(srgba.r)) >> 8)
d[1]=u8((dg * a / m + u32(srgba.g)) >> 8)
d[2]=u8((db * a / m + u32(srgba.b)) >> 8)
d[3]=u8((da * a / m + u32(srgba.a)) >> 8)
}
i0+=dy * dst.stride
}
}
else
{
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut srgba_1:=src0.rgba_64_at(sx, sy)
mut d_1:=dst.pix[i..i+4]
d_1[0]=u8(srgba_1.r >> 8)
d_1[1]=u8(srgba_1.g >> 8)
d_1[2]=u8(srgba_1.b >> 8)
d_1[3]=u8(srgba_1.a >> 8)
}
i0+=dy * dst.stride
}
}
return 
}
else
{
mut mask0 := mask as image.RGBA64Image
if mask0 != unsafe { nil }{
if op == .over{
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut ma:=u32(mask0.rgba_64_at(mx, my).a)
mut srgba_2:=src0.rgba_64_at(sx, sy)
mut d_2:=dst.pix[i..i+4]
mut dr_1:=u32(d_2[0])
mut dg_1:=u32(d_2[1])
mut db_1:=u32(d_2[2])
mut da_1:=u32(d_2[3])
mut a_1:=(m - (u32(srgba_2.a) * ma / m)) * 0x101
d_2[0]=u8((dr_1 * a_1 + u32(srgba_2.r) * ma) / m >> 8)
d_2[1]=u8((dg_1 * a_1 + u32(srgba_2.g) * ma) / m >> 8)
d_2[2]=u8((db_1 * a_1 + u32(srgba_2.b) * ma) / m >> 8)
d_2[3]=u8((da_1 * a_1 + u32(srgba_2.a) * ma) / m >> 8)
}
i0+=dy * dst.stride
}
}
else
{
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut ma_1:=u32(mask0.rgba_64_at(mx, my).a)
mut srgba_3:=src0.rgba_64_at(sx, sy)
mut d_3:=dst.pix[i..i+4]
d_3[0]=u8(u32(srgba_3.r) * ma_1 / m >> 8)
d_3[1]=u8(u32(srgba_3.g) * ma_1 / m >> 8)
d_3[2]=u8(u32(srgba_3.b) * ma_1 / m >> 8)
d_3[3]=u8(u32(srgba_3.a) * ma_1 / m >> 8)
}
i0+=dy * dst.stride
}
}
return 
}
}
}
for y:=y0
; y != y1; y, sy, my=y + dy, sy + dy, my + dy
{
for i, sx, mx:=i0, sx0, mx0
; sx != sx1; i, sx, mx=i + di, sx + dx, mx + dx
{
mut ma_2:=u32(m)
if mask != unsafe { nil }{
_, _, _, ma=mask.at(mx, my).rgba()
}
mut sr, sg, sb, sa:=.src.at(sx, sy).rgba()
mut d_4:=dst.pix[i..i+4]
if op == .over{
mut dr_2:=u32(d_4[0])
mut dg_2:=u32(d_4[1])
mut db_2:=u32(d_4[2])
mut da_2:=u32(d_4[3])
mut a_2:=(m - (sa * ma_2 / m)) * 0x101
d_4[0]=u8((dr_2 * a_2 + sr * ma_2) / m >> 8)
d_4[1]=u8((dg_2 * a_2 + sg * ma_2) / m >> 8)
d_4[2]=u8((db_2 * a_2 + sb * ma_2) / m >> 8)
d_4[3]=u8((da_2 * a_2 + sa * ma_2) / m >> 8)
}
else
{
d_4[0]=u8(sr * ma_2 / m >> 8)
d_4[1]=u8(sg * ma_2 / m >> 8)
d_4[2]=u8(sb * ma_2 / m >> 8)
d_4[3]=u8(sa * ma_2 / m >> 8)
}
}
i0+=dy * dst.stride
}
}

// clamp clamps i to the interval [0, 0xffff].
fn clamp(i i32) i32 {
if i < 0{
return 0
}
if i > 0xffff{
return 0xffff
}
return i
}

// sqDiff returns the squared-difference of x and y, shifted by 2 so that
// adding four of those won't overflow a uint32.
//
// x and y are both assumed to be in the range [0, 0xffff].
fn sq_diff(x i32,y i32) u32 {
mut d:=u32(x - y)
return (d * d) >> 2
}

fn draw_paletted(dst Image,r image.Rectangle,src image.Image,sp image.Point,floyd_steinberg bool) {
mut palette, pix, stride:=[][4]i32(), unsafe { nil }.bytes(), isize(0)
mut ok := dst is &image.Paletted
mut p := dst as &image.Paletted
if ok{
palette=[][4]i32{len: p.palette.len}
for i, col in p.palette {
mut r_1, g, b, a:=col.rgba()
palette[i][0]=i32(r_1)
palette[i][1]=i32(g)
palette[i][2]=i32(b)
palette[i][3]=i32(a)
}
pix, stride=p.pix[p.pix_offset(r_1.min.x, r_1.min.y)..], p.stride
}
mut quant_error_curr,quant_error_next := [][4]i32{}

if floyd_steinberg{
quant_error_curr=[][4]i32{len: r_1.dx()+2}
quant_error_next=[][4]i32{len: r_1.dx()+2}
}
mut px_rgba:=fn (x isize,y isize) u32 {
return .src.at(x, y).rgba()
}

mut src0 := .src
match .src.type_name() {
'RGBA'{
px_rgba=fn (x isize,y isize) u32 {
return src0.rgbaa_t(x, y).rgba()
}

}
'NRGBA'{
px_rgba=fn (x isize,y isize) u32 {
return src0.nrgbaa_t(x, y).rgba()
}

}
'YCbCr'{
px_rgba=fn (x isize,y isize) u32 {
return src0.yc_b_cr_at(x, y).rgba()
}

}
}
mut out:=color.RGBA64{
	a: 0xffff
}
for y_1:=isize(0)
; y_1 != r_1.dy(); y_1++
{
for x_1:=isize(0)
; x_1 != r_1.dx(); x_1++
{
mut sr, sg, sb, sa:=px_rgba(sp.x + x_1, sp.y + y_1)
mut er, eg, eb, ea:=i32(sr), i32(sg), i32(sb), i32(sa)
if floyd_steinberg{
er=clamp(er + quant_error_curr[x_1+1][0] / 16)
eg=clamp(eg + quant_error_curr[x_1+1][1] / 16)
eb=clamp(eb + quant_error_curr[x_1+1][2] / 16)
ea=clamp(ea + quant_error_curr[x_1+1][3] / 16)
}
if palette != unsafe { nil }{
mut best_index, best_sum:=isize(0), u32(1 << 32 - 1)
for index, p_1 in palette {
mut sum:=sq_diff(er, p_1[0]) + sq_diff(eg, p_1[1]) + sq_diff(eb, p_1[2]) + sq_diff(ea, p_1[3])
if sum < best_sum{
best_index, best_sum=index, sum
if sum == 0{
break
}
}
}
pix[y_1 * stride + x_1]=u8(best_index)
if !floyd_steinberg{
continue
}
er-=palette[best_index][0]
eg-=palette[best_index][1]
eb-=palette[best_index][2]
ea-=palette[best_index][3]
}
else
{
out.r=u16(er)
out.g=u16(eg)
out.b=u16(eb)
out.a=u16(ea)
dst.set(r_1.min.x + x_1, r_1.min.y + y_1, &out)
if !floyd_steinberg{
continue
}
sr, sg, sb, sa=dst.at(r_1.min.x + x_1, r_1.min.y + y_1).rgba()
er-=i32(sr)
eg-=i32(sg)
eb-=i32(sb)
ea-=i32(sa)
}
quant_error_next[x_1+0][0]+=er * 3
quant_error_next[x_1+0][1]+=eg * 3
quant_error_next[x_1+0][2]+=eb * 3
quant_error_next[x_1+0][3]+=ea * 3
quant_error_next[x_1+1][0]+=er * 5
quant_error_next[x_1+1][1]+=eg * 5
quant_error_next[x_1+1][2]+=eb * 5
quant_error_next[x_1+1][3]+=ea * 5
quant_error_next[x_1+2][0]+=er * 1
quant_error_next[x_1+2][1]+=eg * 1
quant_error_next[x_1+2][2]+=eb * 1
quant_error_next[x_1+2][3]+=ea * 1
quant_error_curr[x_1+2][0]+=er * 7
quant_error_curr[x_1+2][1]+=eg * 7
quant_error_curr[x_1+2][2]+=eb * 7
quant_error_curr[x_1+2][3]+=ea * 7
}
if floyd_steinberg{
quant_error_curr, quant_error_next=quant_error_next, quant_error_curr
clear(quant_error_next)
}
}
}
