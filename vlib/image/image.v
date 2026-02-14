module image

import image.color
// Config holds an image's color model and dimensions.
pub struct Config {
pub mut:
	color_model color.Model
	width isize
	height isize
}

// Image is a finite rectangular grid of [color.Color] values taken from a color
// model.
pub interface Image {
// ColorModel returns the Image's color model.
	color_model() color.Model
// Bounds returns the domain for which At can return non-zero color.
// The bounds do not necessarily contain the point (0, 0).
	bounds() Rectangle
// At returns the color of the pixel at (x, y).
// At(Bounds().Min.X, Bounds().Min.Y) returns the upper-left pixel of the grid.
// At(Bounds().Max.X-1, Bounds().Max.Y-1) returns the lower-right one.
	at(x isize,y isize) color.Color
}

// RGBA64Image is an [Image] whose pixels can be converted directly to a
// color.RGBA64.
pub interface RGBA64Image {
// RGBA64At returns the RGBA64 color of the pixel at (x, y). It is
// equivalent to calling At(x, y).RGBA() and converting the resulting
// 32-bit return values to a color.RGBA64, but it can avoid allocations
// from converting concrete color types to the color.Color interface type.
	rgba_64_at(x isize,y isize) color.RGBA64
}

// PalettedImage is an image whose colors may come from a limited palette.
// If m is a PalettedImage and m.ColorModel() returns a [color.Palette] p,
// then m.At(x, y) should be equivalent to p[m.ColorIndexAt(x, y)]. If m's
// color model is not a color.Palette, then ColorIndexAt's behavior is
// undefined.
pub interface PalettedImage {
// ColorIndexAt returns the palette index of the pixel at (x, y).
	color_index_at(x isize,y isize) u8
}


// pixelBufferLength returns the length of the []uint8 typed Pix slice field
// for the NewXxx functions. Conceptually, this is just (bpp * width * height),
// but this function panics if at least one of those is negative or if the
// computation would overflow the int type.
//
// This panics instead of returning an error because of backwards
// compatibility. The NewXxx functions do not return an error.
fn pixel_buffer_length(bytes_per_pixel isize,r Rectangle,image_type_name string) isize {
mut total_length:=mul3_non_neg(bytes_per_pixel, r.dx(), r.dy())
if total_length < 0{
panic('image: New'+image_type_name+' Rectangle has huge or negative dimensions')
}
return total_length
}
// RGBA is an in-memory image whose At method returns [color.RGBA] values.
pub struct RGBA {
pub mut:
// Pix holds the image's pixels, in R, G, B, A order. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*4].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p RGBA) color_model() color.Model {
return color.rgbam_odel
}

pub fn (mut p RGBA) bounds() Rectangle {
return p.rect
}

pub fn (mut p RGBA) at(x isize,y isize) color.Color {
return p.rgbaa_t(x, y)
}

pub fn (mut p RGBA) rgba_64_at(x isize,y isize) color.RGBA64 {
if !(Point{
x
y
}.in_(p.rect)){
return color.RGBA64{}
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
mut r:=u16(s[0])
mut g:=u16(s[1])
mut b:=u16(s[2])
mut a:=u16(s[3])
return color.RGBA64{
(r << 8) | r
(g << 8) | g
(b << 8) | b
(a << 8) | a
}
}

pub fn (mut p RGBA) rgbaa_t(x isize,y isize) color.RGBA {
if !(Point{
x
y
}.in_(p.rect)){
return color.RGBA{}
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
return color.RGBA{
s[0]
s[1]
s[2]
s[3]
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p RGBA) pix_offset(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 4
}

pub fn (mut p RGBA) set(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut c1:=color.rgbam_odel.convert(c)
mut s:=p.pix[i..i+4]
s[0]=c1.r
s[1]=c1.g
s[2]=c1.b
s[3]=c1.a
}

pub fn (mut p RGBA) set_rgba_64(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
s[0]=u8(c.r >> 8)
s[1]=u8(c.g >> 8)
s[2]=u8(c.b >> 8)
s[3]=u8(c.a >> 8)
}

pub fn (mut p RGBA) set_rgba(x isize,y isize,c color.RGBA) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
s[0]=c.r
s[1]=c.g
s[2]=c.b
s[3]=c.a
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p RGBA) sub_image(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &RGBA{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &RGBA{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p RGBA) opaque() bool {
if p.rect.empty(){
return true
}
mut i0, i1:=isize(3), p.rect.dx() * 4
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for i:=i0
; i < i1; i+=4
{
if p.pix[i] != 0xff{
return false
}
}
i0+=p.stride
i1+=p.stride
}
return true
}

// NewRGBA returns a new [RGBA] image with the given bounds.
pub fn new_rgba(r Rectangle) &RGBA {
return &RGBA{
	pix: []u8{len: pixel_buffer_length(4, r, 'RGBA')}
	stride: 4 * r.dx()
	rect: r
}
}
// RGBA64 is an in-memory image whose At method returns [color.RGBA64] values.
pub struct RGBA64 {
pub mut:
// Pix holds the image's pixels, in R, G, B, A order and big-endian format. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*8].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p RGBA64) color_model_1() color.Model {
return color.rgba_64_model
}

pub fn (mut p RGBA64) bounds_1() Rectangle {
return p.rect
}

pub fn (mut p RGBA64) at_1(x isize,y isize) color.Color {
return p.rgba_64_at(x, y)
}

pub fn (mut p RGBA64) rgba_64_at_1(x isize,y isize) color.RGBA64 {
if !(Point{
x
y
}.in_(p.rect)){
return color.RGBA64{}
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+8]
return color.RGBA64{
u16(s[0]) << 8 | u16(s[1])
u16(s[2]) << 8 | u16(s[3])
u16(s[4]) << 8 | u16(s[5])
u16(s[6]) << 8 | u16(s[7])
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p RGBA64) pix_offset_1(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 8
}

pub fn (mut p RGBA64) set_1(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut c1:=color.rgba_64_model.convert(c)
mut s:=p.pix[i..i+8]
s[0]=u8(c1.r >> 8)
s[1]=u8(c1.r)
s[2]=u8(c1.g >> 8)
s[3]=u8(c1.g)
s[4]=u8(c1.b >> 8)
s[5]=u8(c1.b)
s[6]=u8(c1.a >> 8)
s[7]=u8(c1.a)
}

pub fn (mut p RGBA64) set_rgba_64_1(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+8]
s[0]=u8(c.r >> 8)
s[1]=u8(c.r)
s[2]=u8(c.g >> 8)
s[3]=u8(c.g)
s[4]=u8(c.b >> 8)
s[5]=u8(c.b)
s[6]=u8(c.a >> 8)
s[7]=u8(c.a)
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p RGBA64) sub_image_1(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &RGBA64{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &RGBA64{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p RGBA64) opaque_1() bool {
if p.rect.empty(){
return true
}
mut i0, i1:=isize(6), p.rect.dx() * 8
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for i:=i0
; i < i1; i+=8
{
if p.pix[i+0] != 0xff || p.pix[i+1] != 0xff{
return false
}
}
i0+=p.stride
i1+=p.stride
}
return true
}

// NewRGBA64 returns a new [RGBA64] image with the given bounds.
pub fn new_rgba_64(r Rectangle) &RGBA64 {
return &RGBA64{
	pix: []u8{len: pixel_buffer_length(8, r, 'RGBA64')}
	stride: 8 * r.dx()
	rect: r
}
}
// NRGBA is an in-memory image whose At method returns [color.NRGBA] values.
pub struct NRGBA {
pub mut:
// Pix holds the image's pixels, in R, G, B, A order. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*4].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p NRGBA) color_model_2() color.Model {
return color.nrgbam_odel
}

pub fn (mut p NRGBA) bounds_2() Rectangle {
return p.rect
}

pub fn (mut p NRGBA) at_2(x isize,y isize) color.Color {
return p.nrgbaa_t(x, y)
}

pub fn (mut p NRGBA) rgba_64_at_2(x isize,y isize) color.RGBA64 {
mut r, g, b, a:=p.nrgbaa_t(x, y).rgba()
return color.RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

pub fn (mut p NRGBA) nrgbaa_t(x isize,y isize) color.NRGBA {
if !(Point{
x
y
}.in_(p.rect)){
return color.NRGBA{}
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
return color.NRGBA{
s[0]
s[1]
s[2]
s[3]
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p NRGBA) pix_offset_2(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 4
}

pub fn (mut p NRGBA) set_2(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut c1:=color.nrgbam_odel.convert(c)
mut s:=p.pix[i..i+4]
s[0]=c1.r
s[1]=c1.g
s[2]=c1.b
s[3]=c1.a
}

pub fn (mut p NRGBA) set_rgba_64_2(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut r, g, b, a:=u32(c.r), u32(c.g), u32(c.b), u32(c.a)
if (a != 0) && (a != 0xffff){
r=(r * 0xffff) / a
g=(g * 0xffff) / a
b=(b * 0xffff) / a
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
s[0]=u8(r >> 8)
s[1]=u8(g >> 8)
s[2]=u8(b >> 8)
s[3]=u8(a >> 8)
}

pub fn (mut p NRGBA) set_nrgba(x isize,y isize,c color.NRGBA) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
s[0]=c.r
s[1]=c.g
s[2]=c.b
s[3]=c.a
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p NRGBA) sub_image_2(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &NRGBA{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &NRGBA{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p NRGBA) opaque_2() bool {
if p.rect.empty(){
return true
}
mut i0, i1:=isize(3), p.rect.dx() * 4
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for i:=i0
; i < i1; i+=4
{
if p.pix[i] != 0xff{
return false
}
}
i0+=p.stride
i1+=p.stride
}
return true
}

// NewNRGBA returns a new [NRGBA] image with the given bounds.
pub fn new_nrgba(r Rectangle) &NRGBA {
return &NRGBA{
	pix: []u8{len: pixel_buffer_length(4, r, 'NRGBA')}
	stride: 4 * r.dx()
	rect: r
}
}
// NRGBA64 is an in-memory image whose At method returns [color.NRGBA64] values.
pub struct NRGBA64 {
pub mut:
// Pix holds the image's pixels, in R, G, B, A order and big-endian format. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*8].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p NRGBA64) color_model_3() color.Model {
return color.nrgba_64_model
}

pub fn (mut p NRGBA64) bounds_3() Rectangle {
return p.rect
}

pub fn (mut p NRGBA64) at_3(x isize,y isize) color.Color {
return p.nrgba_64_at(x, y)
}

pub fn (mut p NRGBA64) rgba_64_at_3(x isize,y isize) color.RGBA64 {
mut r, g, b, a:=p.nrgba_64_at(x, y).rgba()
return color.RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

pub fn (mut p NRGBA64) nrgba_64_at(x isize,y isize) color.NRGBA64 {
if !(Point{
x
y
}.in_(p.rect)){
return color.NRGBA64{}
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+8]
return color.NRGBA64{
u16(s[0]) << 8 | u16(s[1])
u16(s[2]) << 8 | u16(s[3])
u16(s[4]) << 8 | u16(s[5])
u16(s[6]) << 8 | u16(s[7])
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p NRGBA64) pix_offset_3(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 8
}

pub fn (mut p NRGBA64) set_3(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut c1:=color.nrgba_64_model.convert(c)
mut s:=p.pix[i..i+8]
s[0]=u8(c1.r >> 8)
s[1]=u8(c1.r)
s[2]=u8(c1.g >> 8)
s[3]=u8(c1.g)
s[4]=u8(c1.b >> 8)
s[5]=u8(c1.b)
s[6]=u8(c1.a >> 8)
s[7]=u8(c1.a)
}

pub fn (mut p NRGBA64) set_rgba_64_3(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut r, g, b, a:=u32(c.r), u32(c.g), u32(c.b), u32(c.a)
if (a != 0) && (a != 0xffff){
r=(r * 0xffff) / a
g=(g * 0xffff) / a
b=(b * 0xffff) / a
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+8]
s[0]=u8(r >> 8)
s[1]=u8(r)
s[2]=u8(g >> 8)
s[3]=u8(g)
s[4]=u8(b >> 8)
s[5]=u8(b)
s[6]=u8(a >> 8)
s[7]=u8(a)
}

pub fn (mut p NRGBA64) set_nrgba_64(x isize,y isize,c color.NRGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+8]
s[0]=u8(c.r >> 8)
s[1]=u8(c.r)
s[2]=u8(c.g >> 8)
s[3]=u8(c.g)
s[4]=u8(c.b >> 8)
s[5]=u8(c.b)
s[6]=u8(c.a >> 8)
s[7]=u8(c.a)
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p NRGBA64) sub_image_3(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &NRGBA64{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &NRGBA64{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p NRGBA64) opaque_3() bool {
if p.rect.empty(){
return true
}
mut i0, i1:=isize(6), p.rect.dx() * 8
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for i:=i0
; i < i1; i+=8
{
if p.pix[i+0] != 0xff || p.pix[i+1] != 0xff{
return false
}
}
i0+=p.stride
i1+=p.stride
}
return true
}

// NewNRGBA64 returns a new [NRGBA64] image with the given bounds.
pub fn new_nrgba_64(r Rectangle) &NRGBA64 {
return &NRGBA64{
	pix: []u8{len: pixel_buffer_length(8, r, 'NRGBA64')}
	stride: 8 * r.dx()
	rect: r
}
}
// Alpha is an in-memory image whose At method returns [color.Alpha] values.
pub struct Alpha {
pub mut:
// Pix holds the image's pixels, as alpha values. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*1].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p Alpha) color_model_4() color.Model {
return color.alpha_model
}

pub fn (mut p Alpha) bounds_4() Rectangle {
return p.rect
}

pub fn (mut p Alpha) at_4(x isize,y isize) color.Color {
return p.alpha_at(x, y)
}

pub fn (mut p Alpha) rgba_64_at_4(x isize,y isize) color.RGBA64 {
mut a:=u16(p.alpha_at(x, y).a)
a|=a << 8
return color.RGBA64{
a
a
a
a
}
}

pub fn (mut p Alpha) alpha_at(x isize,y isize) color.Alpha {
if !(Point{
x
y
}.in_(p.rect)){
return color.Alpha{}
}
mut i:=p.pix_offset(x, y)
return color.Alpha{
p.pix[i]
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p Alpha) pix_offset_4(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 1
}

pub fn (mut p Alpha) set_4(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=color.alpha_model.convert(c).a
}

pub fn (mut p Alpha) set_rgba_64_4(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=u8(c.a >> 8)
}

pub fn (mut p Alpha) set_alpha(x isize,y isize,c color.Alpha) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=c.a
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p Alpha) sub_image_4(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &Alpha{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &Alpha{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p Alpha) opaque_4() bool {
if p.rect.empty(){
return true
}
mut i0, i1:=isize(0), p.rect.dx()
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for i:=i0
; i < i1; i++
{
if p.pix[i] != 0xff{
return false
}
}
i0+=p.stride
i1+=p.stride
}
return true
}

// NewAlpha returns a new [Alpha] image with the given bounds.
pub fn new_alpha(r Rectangle) &Alpha {
return &Alpha{
	pix: []u8{len: pixel_buffer_length(1, r, 'Alpha')}
	stride: 1 * r.dx()
	rect: r
}
}
// Alpha16 is an in-memory image whose At method returns [color.Alpha16] values.
pub struct Alpha16 {
pub mut:
// Pix holds the image's pixels, as alpha values in big-endian format. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*2].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p Alpha16) color_model_5() color.Model {
return color.alpha16_model
}

pub fn (mut p Alpha16) bounds_5() Rectangle {
return p.rect
}

pub fn (mut p Alpha16) at_5(x isize,y isize) color.Color {
return p.alpha16_at(x, y)
}

pub fn (mut p Alpha16) rgba_64_at_5(x isize,y isize) color.RGBA64 {
mut a:=p.alpha16_at(x, y).a
return color.RGBA64{
a
a
a
a
}
}

pub fn (mut p Alpha16) alpha16_at(x isize,y isize) color.Alpha16 {
if !(Point{
x
y
}.in_(p.rect)){
return color.Alpha16{}
}
mut i:=p.pix_offset(x, y)
return color.Alpha16{
u16(p.pix[i+0]) << 8 | u16(p.pix[i+1])
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p Alpha16) pix_offset_5(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 2
}

pub fn (mut p Alpha16) set_5(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut c1:=color.alpha16_model.convert(c)
p.pix[i+0]=u8(c1.a >> 8)
p.pix[i+1]=u8(c1.a)
}

pub fn (mut p Alpha16) set_rgba_64_5(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i+0]=u8(c.a >> 8)
p.pix[i+1]=u8(c.a)
}

pub fn (mut p Alpha16) set_alpha16(x isize,y isize,c color.Alpha16) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i+0]=u8(c.a >> 8)
p.pix[i+1]=u8(c.a)
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p Alpha16) sub_image_5(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &Alpha16{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &Alpha16{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p Alpha16) opaque_5() bool {
if p.rect.empty(){
return true
}
mut i0, i1:=isize(0), p.rect.dx() * 2
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for i:=i0
; i < i1; i+=2
{
if p.pix[i+0] != 0xff || p.pix[i+1] != 0xff{
return false
}
}
i0+=p.stride
i1+=p.stride
}
return true
}

// NewAlpha16 returns a new [Alpha16] image with the given bounds.
pub fn new_alpha16(r Rectangle) &Alpha16 {
return &Alpha16{
	pix: []u8{len: pixel_buffer_length(2, r, 'Alpha16')}
	stride: 2 * r.dx()
	rect: r
}
}
// Gray is an in-memory image whose At method returns [color.Gray] values.
pub struct Gray {
pub mut:
// Pix holds the image's pixels, as gray values. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*1].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p Gray) color_model_6() color.Model {
return color.gray_model
}

pub fn (mut p Gray) bounds_6() Rectangle {
return p.rect
}

pub fn (mut p Gray) at_6(x isize,y isize) color.Color {
return p.gray_at(x, y)
}

pub fn (mut p Gray) rgba_64_at_6(x isize,y isize) color.RGBA64 {
mut gray:=u16(p.gray_at(x, y).y)
gray|=gray << 8
return color.RGBA64{
gray
gray
gray
0xffff
}
}

pub fn (mut p Gray) gray_at(x isize,y isize) color.Gray {
if !(Point{
x
y
}.in_(p.rect)){
return color.Gray{}
}
mut i:=p.pix_offset(x, y)
return color.Gray{
p.pix[i]
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p Gray) pix_offset_6(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 1
}

pub fn (mut p Gray) set_6(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=color.gray_model.convert(c).y
}

pub fn (mut p Gray) set_rgba_64_6(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut gray:=(19595 * u32(c.r) + 38470 * u32(c.g) + 7471 * u32(c.b) + 1 << 15) >> 24
mut i:=p.pix_offset(x, y)
p.pix[i]=u8(gray)
}

pub fn (mut p Gray) set_gray(x isize,y isize,c color.Gray) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=c.y
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p Gray) sub_image_6(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &Gray{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &Gray{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p Gray) opaque_6() bool {
return true
}

// NewGray returns a new [Gray] image with the given bounds.
pub fn new_gray(r Rectangle) &Gray {
return &Gray{
	pix: []u8{len: pixel_buffer_length(1, r, 'Gray')}
	stride: 1 * r.dx()
	rect: r
}
}
// Gray16 is an in-memory image whose At method returns [color.Gray16] values.
pub struct Gray16 {
pub mut:
// Pix holds the image's pixels, as gray values in big-endian format. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*2].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p Gray16) color_model_7() color.Model {
return color.gray16_model
}

pub fn (mut p Gray16) bounds_7() Rectangle {
return p.rect
}

pub fn (mut p Gray16) at_7(x isize,y isize) color.Color {
return p.gray16_at(x, y)
}

pub fn (mut p Gray16) rgba_64_at_7(x isize,y isize) color.RGBA64 {
mut gray:=p.gray16_at(x, y).y
return color.RGBA64{
gray
gray
gray
0xffff
}
}

pub fn (mut p Gray16) gray16_at(x isize,y isize) color.Gray16 {
if !(Point{
x
y
}.in_(p.rect)){
return color.Gray16{}
}
mut i:=p.pix_offset(x, y)
return color.Gray16{
u16(p.pix[i+0]) << 8 | u16(p.pix[i+1])
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p Gray16) pix_offset_7(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 2
}

pub fn (mut p Gray16) set_7(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut c1:=color.gray16_model.convert(c)
p.pix[i+0]=u8(c1.y >> 8)
p.pix[i+1]=u8(c1.y)
}

pub fn (mut p Gray16) set_rgba_64_7(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut gray:=(19595 * u32(c.r) + 38470 * u32(c.g) + 7471 * u32(c.b) + 1 << 15) >> 16
mut i:=p.pix_offset(x, y)
p.pix[i+0]=u8(gray >> 8)
p.pix[i+1]=u8(gray)
}

pub fn (mut p Gray16) set_gray16(x isize,y isize,c color.Gray16) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i+0]=u8(c.y >> 8)
p.pix[i+1]=u8(c.y)
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p Gray16) sub_image_7(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &Gray16{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &Gray16{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p Gray16) opaque_7() bool {
return true
}

// NewGray16 returns a new [Gray16] image with the given bounds.
pub fn new_gray16(r Rectangle) &Gray16 {
return &Gray16{
	pix: []u8{len: pixel_buffer_length(2, r, 'Gray16')}
	stride: 2 * r.dx()
	rect: r
}
}
// CMYK is an in-memory image whose At method returns [color.CMYK] values.
pub struct CMYK {
pub mut:
// Pix holds the image's pixels, in C, M, Y, K order. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*4].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
}


pub fn (mut p CMYK) color_model_8() color.Model {
return color.cmykm_odel
}

pub fn (mut p CMYK) bounds_8() Rectangle {
return p.rect
}

pub fn (mut p CMYK) at_8(x isize,y isize) color.Color {
return p.cmyka_t(x, y)
}

pub fn (mut p CMYK) rgba_64_at_8(x isize,y isize) color.RGBA64 {
mut r, g, b, a:=p.cmyka_t(x, y).rgba()
return color.RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

pub fn (mut p CMYK) cmyka_t(x isize,y isize) color.CMYK {
if !(Point{
x
y
}.in_(p.rect)){
return color.CMYK{}
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
return color.CMYK{
s[0]
s[1]
s[2]
s[3]
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p CMYK) pix_offset_8(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 4
}

pub fn (mut p CMYK) set_8(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut c1:=color.cmykm_odel.convert(c)
mut s:=p.pix[i..i+4]
s[0]=c1.c
s[1]=c1.m
s[2]=c1.y
s[3]=c1.k
}

pub fn (mut p CMYK) set_rgba_64_8(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut cc, mm, yy, kk:=color.rgbt_o_cmyk(u8(c.r >> 8), u8(c.g >> 8), u8(c.b >> 8))
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
s[0]=cc
s[1]=mm
s[2]=yy
s[3]=kk
}

pub fn (mut p CMYK) set_cmyk(x isize,y isize,c color.CMYK) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
mut s:=p.pix[i..i+4]
s[0]=c.c
s[1]=c.m
s[2]=c.y
s[3]=c.k
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p CMYK) sub_image_8(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &CMYK{}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &CMYK{
	pix: p.pix[i..]
	stride: p.stride
	rect: r
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p CMYK) opaque_8() bool {
return true
}

// NewCMYK returns a new CMYK image with the given bounds.
pub fn new_cmyk(r Rectangle) &CMYK {
return &CMYK{
	pix: []u8{len: pixel_buffer_length(4, r, 'CMYK')}
	stride: 4 * r.dx()
	rect: r
}
}
// Paletted is an in-memory image of uint8 indices into a given palette.
pub struct Paletted {
pub mut:
// Pix holds the image's pixels, as palette indices. The pixel at
// (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*1].
	pix []u8
// Stride is the Pix stride (in bytes) between vertically adjacent pixels.
	stride isize
// Rect is the image's bounds.
	rect Rectangle
// Palette is the image's palette.
	palette color.Palette
}


pub fn (mut p Paletted) color_model_9() color.Model {
return p.palette
}

pub fn (mut p Paletted) bounds_9() Rectangle {
return p.rect
}

pub fn (mut p Paletted) at_9(x isize,y isize) color.Color {
if p.palette.len == 0{
return unsafe { nil }
}
if !(Point{
x
y
}.in_(p.rect)){
return p.palette[0]
}
mut i:=p.pix_offset(x, y)
return p.palette[p.pix[i]]
}

pub fn (mut p Paletted) rgba_64_at_9(x isize,y isize) color.RGBA64 {
if p.palette.len == 0{
return color.RGBA64{}
}
mut c:=color.color(unsafe { nil })
if !(Point{
x
y
}.in_(p.rect)){
c=p.palette[0]
}
else
{
mut i:=p.pix_offset(x, y)
c=p.palette[p.pix[i]]
}
mut r, g, b, a:=c.rgba()
return color.RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

// PixOffset returns the index of the first element of Pix that corresponds to
// the pixel at (x, y).
pub fn (mut p Paletted) pix_offset_9(x isize,y isize) isize {
return (y - p.rect.min.y) * p.stride + (x - p.rect.min.x) * 1
}

pub fn (mut p Paletted) set_9(x isize,y isize,c color.Color) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=u8(p.palette.index(c))
}

pub fn (mut p Paletted) set_rgba_64_9(x isize,y isize,c color.RGBA64) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=u8(p.palette.index(c))
}

pub fn (mut p Paletted) color_index_at(x isize,y isize) u8 {
if !(Point{
x
y
}.in_(p.rect)){
return 0
}
mut i:=p.pix_offset(x, y)
return p.pix[i]
}

pub fn (mut p Paletted) set_color_index(x isize,y isize,index u8) {
if !(Point{
x
y
}.in_(p.rect)){
return 
}
mut i:=p.pix_offset(x, y)
p.pix[i]=index
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p Paletted) sub_image_9(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &Paletted{
	palette: p.palette
}
}
mut i:=p.pix_offset(r.min.x, r.min.y)
return &Paletted{
	pix: p.pix[i..]
	stride: p.stride
	rect: p.rect.intersect(r)
	palette: p.palette
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p Paletted) opaque_9() bool {
mut present := [256]Bool{}

mut i0, i1:=isize(0), p.rect.dx()
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for _, c in p.pix[i0..i1] {
present[c]=true
}
i0+=p.stride
i1+=p.stride
}
for i, c_1 in p.palette {
if !present[i]{
continue
}
_, _, _, a:=c_1.rgba()
if a != 0xffff{
return false
}
}
return true
}

// NewPaletted returns a new [Paletted] image with the given width, height and
// palette.
pub fn new_paletted(r Rectangle,p color.Palette) &Paletted {
return &Paletted{
	pix: []u8{len: pixel_buffer_length(1, r, 'Paletted')}
	stride: 1 * r.dx()
	rect: r
	palette: p
}
}
