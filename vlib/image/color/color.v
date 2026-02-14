module color

// Color can convert itself to alpha-premultiplied 16-bits per channel RGBA.
// The conversion may be lossy.
pub interface Color {
// RGBA returns the alpha-premultiplied red, green, blue and alpha values
// for the color. Each value ranges within [0, 0xffff], but is represented
// by a uint32 so that multiplying by a blend factor up to 0xffff will not
// overflow.
//
// An alpha-premultiplied color component c has been scaled by alpha (a),
// so has valid values 0 <= c <= a.
	rgba() u32
}

// RGBA represents a traditional 32-bit alpha-premultiplied color, having 8
// bits for each of red, green, blue and alpha.
//
// An alpha-premultiplied color component C has been scaled by alpha (A), so
// has valid values 0 <= C <= A.
pub struct RGBA {
pub mut:
	r u8
	g u8
	b u8
	a u8
}


pub fn (c RGBA) rgba() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
r=u32(c.r)
r|=r << 8
g=u32(c.g)
g|=g << 8
b=u32(c.b)
b|=b << 8
a=u32(c.a)
a|=a << 8
return r, g, b, a
}
// RGBA64 represents a 64-bit alpha-premultiplied color, having 16 bits for
// each of red, green, blue and alpha.
//
// An alpha-premultiplied color component C has been scaled by alpha (A), so
// has valid values 0 <= C <= A.
pub struct RGBA64 {
pub mut:
	r u16
	g u16
	b u16
	a u16
}


pub fn (c RGBA64) rgba_1() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
return u32(c.r), u32(c.g), u32(c.b), u32(c.a)
}
// NRGBA represents a non-alpha-premultiplied 32-bit color.
pub struct NRGBA {
pub mut:
	r u8
	g u8
	b u8
	a u8
}


pub fn (c NRGBA) rgba_2() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
r=u32(c.r)
r|=r << 8
r*=u32(c.a)
r/=0xff
g=u32(c.g)
g|=g << 8
g*=u32(c.a)
g/=0xff
b=u32(c.b)
b|=b << 8
b*=u32(c.a)
b/=0xff
a=u32(c.a)
a|=a << 8
return r, g, b, a
}
// NRGBA64 represents a non-alpha-premultiplied 64-bit color,
// having 16 bits for each of red, green, blue and alpha.
pub struct NRGBA64 {
pub mut:
	r u16
	g u16
	b u16
	a u16
}


pub fn (c NRGBA64) rgba_3() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
r=u32(c.r)
r*=u32(c.a)
r/=0xffff
g=u32(c.g)
g*=u32(c.a)
g/=0xffff
b=u32(c.b)
b*=u32(c.a)
b/=0xffff
a=u32(c.a)
return r, g, b, a
}
// Alpha represents an 8-bit alpha color.
pub struct Alpha {
pub mut:
	a u8
}


pub fn (c Alpha) rgba_4() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
a=u32(c.a)
a|=a << 8
return a, a, a, a
}
// Alpha16 represents a 16-bit alpha color.
pub struct Alpha16 {
pub mut:
	a u16
}


pub fn (c Alpha16) rgba_5() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
a=u32(c.a)
return a, a, a, a
}
// Gray represents an 8-bit grayscale color.
pub struct Gray {
pub mut:
	y u8
}


pub fn (c Gray) rgba_6() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
mut y:=u32(c.y)
y|=y << 8
return y, y, y, 0xffff
}
// Gray16 represents a 16-bit grayscale color.
pub struct Gray16 {
pub mut:
	y u16
}


pub fn (c Gray16) rgba_7() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
mut y:=u32(c.y)
return y, y, y, 0xffff
}
// Model can convert any [Color] to one from its own color model. The conversion
// may be lossy.
pub interface Model {
	convert(c Color) Color
}


// ModelFunc returns a [Model] that invokes f to implement the conversion.
pub fn model_func(f fn(Color) Color) Model {
return &ModelFunc{
f
}
}
struct ModelFunc {
pub mut:
	f fn(Color) Color = unsafe { nil }
}


pub fn (mut m ModelFunc) convert(c Color) Color {
return m.f(c)
}
// Models for the standard color types.
__global rgbam_odel Model
__global rgba_64_model Model
__global nrgbam_odel Model
__global nrgba_64_model Model
__global alpha_model Model
__global alpha16_model Model
__global gray_model Model
__global gray16_model Model

fn rgba_model(c Color) Color {
mut ok := c is RGBA
if ok{
return c
}
mut r, g, b, a:=c.rgba()
return RGBA{
u8(r >> 8)
u8(g >> 8)
u8(b >> 8)
u8(a >> 8)
}
}

fn rgba64_model(c Color) Color {
mut ok := c is RGBA64
if ok{
return c
}
mut r, g, b, a:=c.rgba()
return RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

fn nrgba_model(c Color) Color {
mut ok := c is NRGBA
if ok{
return c
}
mut r, g, b, a:=c.rgba()
if a == 0xffff{
return NRGBA{
u8(r >> 8)
u8(g >> 8)
u8(b >> 8)
0xff
}
}
if a == 0{
return NRGBA{
0
0
0
0
}
}
r=(r * 0xffff) / a
g=(g * 0xffff) / a
b=(b * 0xffff) / a
return NRGBA{
u8(r >> 8)
u8(g >> 8)
u8(b >> 8)
u8(a >> 8)
}
}

fn nrgba64_model(c Color) Color {
mut ok := c is NRGBA64
if ok{
return c
}
mut r, g, b, a:=c.rgba()
if a == 0xffff{
return NRGBA64{
u16(r)
u16(g)
u16(b)
0xffff
}
}
if a == 0{
return NRGBA64{
0
0
0
0
}
}
r=(r * 0xffff) / a
g=(g * 0xffff) / a
b=(b * 0xffff) / a
return NRGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

fn alpha_model(c Color) Color {
mut ok := c is Alpha
if ok{
return c
}
_, _, _, a:=c.rgba()
return Alpha{
u8(a >> 8)
}
}

fn alpha16_model(c Color) Color {
mut ok := c is Alpha16
if ok{
return c
}
_, _, _, a:=c.rgba()
return Alpha16{
u16(a)
}
}

fn gray_model(c Color) Color {
mut ok := c is Gray
if ok{
return c
}
mut r, g, b, _:=c.rgba()
mut y:=(19595 * r + 38470 * g + 7471 * b + 1 << 15) >> 24
return Gray{
u8(y)
}
}

fn gray16_model(c Color) Color {
mut ok := c is Gray16
if ok{
return c
}
mut r, g, b, _:=c.rgba()
mut y:=(19595 * r + 38470 * g + 7471 * b + 1 << 15) >> 16
return Gray16{
u16(y)
}
}
// Palette is a palette of colors.
type Palette = []Color

// Convert returns the palette color closest to c in Euclidean R,G,B space.
pub fn (p Palette) convert_1(c Color) Color {
if p.len == 0{
return unsafe { nil }
}
return p[p.index(c)]
}

// Index returns the index of the palette color closest to c in Euclidean
// R,G,B,A space.
pub fn (p Palette) index(c Color) isize {
mut cr, cg, cb, ca:=c.rgba()
mut ret, best_sum:=isize(0), u32(1 << 32 - 1)
for i, v in p {
mut vr, vg, vb, va:=v.rgba()
mut sum:=sq_diff(cr, vr) + sq_diff(cg, vg) + sq_diff(cb, vb) + sq_diff(ca, va)
if sum < best_sum{
if sum == 0{
return i
}
ret, best_sum=i, sum
}
}
return ret
}

// sqDiff returns the squared-difference of x and y, shifted by 2 so that
// adding four of those won't overflow a uint32.
//
// x and y are both assumed to be in the range [0, 0xffff].
fn sq_diff(x u32,y u32) u32 {
mut d:=x - y
return (d * d) >> 2
}
// Standard colors.
__global black = Gray16{
0
}
__global white = Gray16{
0xffff
}
__global transparent = Alpha16{
0
}
__global opaque = Alpha16{
0xffff
}
