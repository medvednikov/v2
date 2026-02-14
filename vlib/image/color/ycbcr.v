module color


// RGBToYCbCr converts an RGB triple to a Y'CbCr triple.
pub fn rgbt_o_yc_b_cr(r u8,g u8,b u8) (u8,u8,u8) {
mut r1:=i32(r)
mut g1:=i32(g)
mut b1:=i32(b)
mut yy:=(19595 * r1 + 38470 * g1 + 7471 * b1 + 1 << 15) >> 16
mut cb:=-11056 * r1 - 21712 * g1 + 32768 * b1 + 257 << 15
if u32(cb) & 0xff000000 == 0{
cb>>=16
}
else
{
cb=~(cb >> 31)
}
mut cr:=32768 * r1 - 27440 * g1 - 5328 * b1 + 257 << 15
if u32(cr) & 0xff000000 == 0{
cr>>=16
}
else
{
cr=~(cr >> 31)
}
return u8(yy), u8(cb), u8(cr)
}

// YCbCrToRGB converts a Y'CbCr triple to an RGB triple.
pub fn yc_b_cr_to_rgb(y u8,cb u8,cr u8) (u8,u8,u8) {
mut yy1:=i32(y) * 0x10101
mut cb1:=i32(cb) - 128
mut cr1:=i32(cr) - 128
mut r:=yy1 + 91881 * cr1
if u32(r) & 0xff000000 == 0{
r>>=16
}
else
{
r=~(r >> 31)
}
mut g:=yy1 - 22554 * cb1 - 46802 * cr1
if u32(g) & 0xff000000 == 0{
g>>=16
}
else
{
g=~(g >> 31)
}
mut b:=yy1 + 116130 * cb1
if u32(b) & 0xff000000 == 0{
b>>=16
}
else
{
b=~(b >> 31)
}
return u8(r), u8(g), u8(b)
}
// YCbCr represents a fully opaque 24-bit Y'CbCr color, having 8 bits each for
// one luma and two chroma components.
//
// JPEG, VP8, the MPEG family and other codecs use this color model. Such
// codecs often use the terms YUV and Y'CbCr interchangeably, but strictly
// speaking, the term YUV applies only to analog video signals, and Y' (luma)
// is Y (luminance) after applying gamma correction.
//
// Conversion between RGB and Y'CbCr is lossy and there are multiple, slightly
// different formulae for converting between the two. This package follows
// the JFIF specification at https://www.w3.org/Graphics/JPEG/jfif3.pdf.
pub struct YCbCr {
pub mut:
	y u8
	cb u8
	cr u8
}


pub fn (c YCbCr) rgba() (u32,u32,u32,u32) {
mut yy1:=i32(c.y) * 0x10101
mut cb1:=i32(c.cb) - 128
mut cr1:=i32(c.cr) - 128
mut r:=yy1 + 91881 * cr1
if u32(r) & 0xff000000 == 0{
r>>=8
}
else
{
r=~(r >> 31) & 0xffff
}
mut g:=yy1 - 22554 * cb1 - 46802 * cr1
if u32(g) & 0xff000000 == 0{
g>>=8
}
else
{
g=~(g >> 31) & 0xffff
}
mut b:=yy1 + 116130 * cb1
if u32(b) & 0xff000000 == 0{
b>>=8
}
else
{
b=~(b >> 31) & 0xffff
}
return u32(r), u32(g), u32(b), 0xffff
}
// YCbCrModel is the [Model] for Y'CbCr colors.
__global yc_b_cr_model Model

fn y_cb_cr_model(c Color) Color {
mut ok := c is YCbCr
if ok{
return c
}
mut r, g, b, _:=c.rgba()
mut y, u, v:=rgbt_o_yc_b_cr(u8(r >> 8), u8(g >> 8), u8(b >> 8))
return YCbCr{
y
u
v
}
}
// NYCbCrA represents a non-alpha-premultiplied Y'CbCr-with-alpha color, having
// 8 bits each for one luma, two chroma and one alpha component.
pub struct NYCbCrA {
	YCbCr
pub mut:
	a u8
}


pub fn (c NYCbCrA) rgba_1() (u32,u32,u32,u32) {
mut yy1:=i32(c.y) * 0x10101
mut cb1:=i32(c.cb) - 128
mut cr1:=i32(c.cr) - 128
mut r:=yy1 + 91881 * cr1
if u32(r) & 0xff000000 == 0{
r>>=8
}
else
{
r=~(r >> 31) & 0xffff
}
mut g:=yy1 - 22554 * cb1 - 46802 * cr1
if u32(g) & 0xff000000 == 0{
g>>=8
}
else
{
g=~(g >> 31) & 0xffff
}
mut b:=yy1 + 116130 * cb1
if u32(b) & 0xff000000 == 0{
b>>=8
}
else
{
b=~(b >> 31) & 0xffff
}
mut a:=u32(c.a) * 0x101
return u32(r) * a / 0xffff, u32(g) * a / 0xffff, u32(b) * a / 0xffff, a
}
// NYCbCrAModel is the [Model] for non-alpha-premultiplied Y'CbCr-with-alpha
// colors.
__global nyc_b_cr_am_odel Model

fn nyc_b_cr_am_odel(c Color) Color {
mut c_1 := c
match c.type_name() {
'NYCbCrA'{
return c
}
'YCbCr'{
return NYCbCrA{
c
0xff
}
}
}
mut r, g, b, a:=c.rgba()
if a != 0{
r=(r * 0xffff) / a
g=(g * 0xffff) / a
b=(b * 0xffff) / a
}
mut y, u, v:=rgbt_o_yc_b_cr(u8(r >> 8), u8(g >> 8), u8(b >> 8))
return NYCbCrA{
YCbCr{
	y: y
	cb: u
	cr: v
}
u8(a >> 8)
}
}

// RGBToCMYK converts an RGB triple to a CMYK quadruple.
pub fn rgbt_o_cmyk(r u8,g u8,b u8) (u8,u8,u8,u8) {
mut rr:=u32(r)
mut gg:=u32(g)
mut bb:=u32(b)
mut w:=rr
if w < gg{
w=gg
}
if w < bb{
w=bb
}
if w == 0{
return 0, 0, 0, 0xff
}
mut c:=(w - rr) * 0xff / w
mut m:=(w - gg) * 0xff / w
mut y:=(w - bb) * 0xff / w
return u8(c), u8(m), u8(y), u8(0xff - w)
}

// CMYKToRGB converts a [CMYK] quadruple to an RGB triple.
pub fn cmykt_o_rgb(c u8,m u8,y u8,k u8) (u8,u8,u8) {
mut w:=0xffff - u32(k) * 0x101
mut r:=(0xffff - u32(c) * 0x101) * w / 0xffff
mut g:=(0xffff - u32(m) * 0x101) * w / 0xffff
mut b:=(0xffff - u32(y) * 0x101) * w / 0xffff
return u8(r >> 8), u8(g >> 8), u8(b >> 8)
}
// CMYK represents a fully opaque CMYK color, having 8 bits for each of cyan,
// magenta, yellow and black.
//
// It is not associated with any particular color profile.
pub struct CMYK {
pub mut:
	c u8
	m u8
	y u8
	k u8
}


pub fn (c CMYK) rgba_2() (u32,u32,u32,u32) {
mut w:=0xffff - u32(c.k) * 0x101
mut r:=(0xffff - u32(c.c) * 0x101) * w / 0xffff
mut g:=(0xffff - u32(c.m) * 0x101) * w / 0xffff
mut b:=(0xffff - u32(c.y) * 0x101) * w / 0xffff
return r, g, b, 0xffff
}
// CMYKModel is the [Model] for CMYK colors.
__global cmykm_odel Model

fn cmyk_model(c Color) Color {
mut ok := c is CMYK
if ok{
return c
}
mut r, g, b, _:=c.rgba()
mut cc, mm, yy, kk:=rgbt_o_cmyk(u8(r >> 8), u8(g >> 8), u8(b >> 8))
return CMYK{
cc
mm
yy
kk
}
}
