module image

import image.color
// YCbCrSubsampleRatio is the chroma subsample ratio used in a YCbCr image.
enum YCbCrSubsampleRatio {
yc_b_cr_subsample_ratio444
yc_b_cr_subsample_ratio422
yc_b_cr_subsample_ratio420
yc_b_cr_subsample_ratio440
yc_b_cr_subsample_ratio411
yc_b_cr_subsample_ratio410
}

pub fn (s YCbCrSubsampleRatio) str() string {
match s{
.yc_b_cr_subsample_ratio444{
return 'YCbCrSubsampleRatio444'
}
.yc_b_cr_subsample_ratio422{
return 'YCbCrSubsampleRatio422'
}
.yc_b_cr_subsample_ratio420{
return 'YCbCrSubsampleRatio420'
}
.yc_b_cr_subsample_ratio440{
return 'YCbCrSubsampleRatio440'
}
.yc_b_cr_subsample_ratio411{
return 'YCbCrSubsampleRatio411'
}
.yc_b_cr_subsample_ratio410{
return 'YCbCrSubsampleRatio410'
}
}
return 'YCbCrSubsampleRatioUnknown'
}
// YCbCr is an in-memory image of Y'CbCr colors. There is one Y sample per
// pixel, but each Cb and Cr sample can span one or more pixels.
// YStride is the Y slice index delta between vertically adjacent pixels.
// CStride is the Cb and Cr slice index delta between vertically adjacent pixels
// that map to separate chroma samples.
// It is not an absolute requirement, but YStride and len(Y) are typically
// multiples of 8, and:
//
//	For 4:4:4, CStride == YStride/1 && len(Cb) == len(Cr) == len(Y)/1.
//	For 4:2:2, CStride == YStride/2 && len(Cb) == len(Cr) == len(Y)/2.
//	For 4:2:0, CStride == YStride/2 && len(Cb) == len(Cr) == len(Y)/4.
//	For 4:4:0, CStride == YStride/1 && len(Cb) == len(Cr) == len(Y)/2.
//	For 4:1:1, CStride == YStride/4 && len(Cb) == len(Cr) == len(Y)/4.
//	For 4:1:0, CStride == YStride/4 && len(Cb) == len(Cr) == len(Y)/8.
pub struct YCbCr {
pub mut:
	y []u8
	cb []u8
	cr []u8
	ys_tride isize
	cs_tride isize
	subsample_ratio YCbCrSubsampleRatio
	rect Rectangle
}


pub fn (mut p YCbCr) color_model() color.Model {
return color.yc_b_cr_model
}

pub fn (mut p YCbCr) bounds() Rectangle {
return p.rect
}

pub fn (mut p YCbCr) at(x isize,y isize) color.Color {
return p.yc_b_cr_at(x, y)
}

pub fn (mut p YCbCr) rgba_64_at(x isize,y isize) color.RGBA64 {
mut r, g, b, a:=p.yc_b_cr_at(x, y).rgba()
return color.RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

pub fn (mut p YCbCr) yc_b_cr_at(x isize,y isize) color.YCbCr {
if !(Point{
x
y
}.in_(p.rect)){
return color.YCbCr{}
}
mut yi:=p.yo_ffset(x, y)
mut ci:=p.co_ffset(x, y)
return color.YCbCr{
p.y[yi]
p.cb[ci]
p.cr[ci]
}
}

// YOffset returns the index of the first element of Y that corresponds to
// the pixel at (x, y).
pub fn (mut p YCbCr) yo_ffset(x isize,y isize) isize {
return (y - p.rect.min.y) * p.ys_tride + (x - p.rect.min.x)
}

// COffset returns the index of the first element of Cb or Cr that corresponds
// to the pixel at (x, y).
pub fn (mut p YCbCr) co_ffset(x isize,y isize) isize {
match p.subsample_ratio{
.yc_b_cr_subsample_ratio422{
return (y - p.rect.min.y) * p.cs_tride + (x / 2 - p.rect.min.x / 2)
}
.yc_b_cr_subsample_ratio420{
return (y / 2 - p.rect.min.y / 2) * p.cs_tride + (x / 2 - p.rect.min.x / 2)
}
.yc_b_cr_subsample_ratio440{
return (y / 2 - p.rect.min.y / 2) * p.cs_tride + (x - p.rect.min.x)
}
.yc_b_cr_subsample_ratio411{
return (y - p.rect.min.y) * p.cs_tride + (x / 4 - p.rect.min.x / 4)
}
.yc_b_cr_subsample_ratio410{
return (y / 2 - p.rect.min.y / 2) * p.cs_tride + (x / 4 - p.rect.min.x / 4)
}
}
return (y - p.rect.min.y) * p.cs_tride + (x - p.rect.min.x)
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p YCbCr) sub_image(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &YCbCr{
	subsample_ratio: p.subsample_ratio
}
}
mut yi:=p.yo_ffset(r.min.x, r.min.y)
mut ci:=p.co_ffset(r.min.x, r.min.y)
return &YCbCr{
	y: p.y[yi..]
	cb: p.cb[ci..]
	cr: p.cr[ci..]
	subsample_ratio: p.subsample_ratio
	ys_tride: p.ys_tride
	cs_tride: p.cs_tride
	rect: r
}
}

pub fn (mut p YCbCr) opaque() bool {
return true
}

fn y_cb_cr_size(r Rectangle,subsample_ratio YCbCrSubsampleRatio) isize {
mut w:=0
mut h:=0
mut cw:=0
mut ch:=0
w, h=r.dx(), r.dy()
match subsample_ratio{
.yc_b_cr_subsample_ratio422{
cw=(r.max.x+1) / 2 - r.min.x / 2
ch=h
}
.yc_b_cr_subsample_ratio420{
cw=(r.max.x+1) / 2 - r.min.x / 2
ch=(r.max.y+1) / 2 - r.min.y / 2
}
.yc_b_cr_subsample_ratio440{
cw=w
ch=(r.max.y+1) / 2 - r.min.y / 2
}
.yc_b_cr_subsample_ratio411{
cw=(r.max.x+3) / 4 - r.min.x / 4
ch=h
}
.yc_b_cr_subsample_ratio410{
cw=(r.max.x+3) / 4 - r.min.x / 4
ch=(r.max.y+1) / 2 - r.min.y / 2
}
else {
cw=w
ch=h
}
}
return w, h, cw, ch
}

// NewYCbCr returns a new YCbCr image with the given bounds and subsample
// ratio.
pub fn new_yc_b_cr(r Rectangle,subsample_ratio YCbCrSubsampleRatio) &YCbCr {
mut w, h, cw, ch:=y_cb_cr_size(r, subsample_ratio)
mut total_length:=add2_non_neg(mul3_non_neg(1, w, h), mul3_non_neg(2, cw, ch))
if total_length < 0{
panic('image: NewYCbCr Rectangle has huge or negative dimensions')
}
mut i0:=w * h + 0 * cw * ch
mut i1:=w * h + 1 * cw * ch
mut i2:=w * h + 2 * cw * ch
mut b:=[]u8{len: i2}
return &YCbCr{
	y: b[..i0]
	cb: b[i0..i1]
	cr: b[i1..i2]
	subsample_ratio: subsample_ratio
	ys_tride: w
	cs_tride: cw
	rect: r
}
}
// NYCbCrA is an in-memory image of non-alpha-premultiplied Y'CbCr-with-alpha
// colors. A and AStride are analogous to the Y and YStride fields of the
// embedded YCbCr.
pub struct NYCbCrA {
	YCbCr
pub mut:
	a []u8
	as_tride isize
}


pub fn (mut p NYCbCrA) color_model_1() color.Model {
return color.nyc_b_cr_am_odel
}

pub fn (mut p NYCbCrA) at_1(x isize,y isize) color.Color {
return p.nyc_b_cr_aa_t(x, y)
}

pub fn (mut p NYCbCrA) rgba_64_at_1(x isize,y isize) color.RGBA64 {
mut r, g, b, a:=p.nyc_b_cr_aa_t(x, y).rgba()
return color.RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

pub fn (mut p NYCbCrA) nyc_b_cr_aa_t(x isize,y isize) color.NYCbCrA {
if !(Point{
	x: x
	y: y
}.in_(p.rect)){
return color.NYCbCrA{}
}
mut yi:=p.yo_ffset(x, y)
mut ci:=p.co_ffset(x, y)
mut ai:=p.ao_ffset(x, y)
return color.NYCbCrA{
color.YCbCr{
	y: p.y[yi]
	cb: p.cb[ci]
	cr: p.cr[ci]
}
p.a[ai]
}
}

// AOffset returns the index of the first element of A that corresponds to the
// pixel at (x, y).
pub fn (mut p NYCbCrA) ao_ffset(x isize,y isize) isize {
return (y - p.rect.min.y) * p.as_tride + (x - p.rect.min.x)
}

// SubImage returns an image representing the portion of the image p visible
// through r. The returned value shares pixels with the original image.
pub fn (mut p NYCbCrA) sub_image_1(r Rectangle) Image {
r=r.intersect(p.rect)
if r.empty(){
return &NYCbCrA{
	yc_b_cr: YCbCr{
	subsample_ratio: p.subsample_ratio
}
}
}
mut yi:=p.yo_ffset(r.min.x, r.min.y)
mut ci:=p.co_ffset(r.min.x, r.min.y)
mut ai:=p.ao_ffset(r.min.x, r.min.y)
return &NYCbCrA{
	yc_b_cr: YCbCr{
	y: p.y[yi..]
	cb: p.cb[ci..]
	cr: p.cr[ci..]
	subsample_ratio: p.subsample_ratio
	ys_tride: p.ys_tride
	cs_tride: p.cs_tride
	rect: r
}
	a: p.a[ai..]
	as_tride: p.as_tride
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut p NYCbCrA) opaque_1() bool {
if p.rect.empty(){
return true
}
mut i0, i1:=isize(0), p.rect.dx()
for y:=p.rect.min.y
; y < p.rect.max.y; y++
{
for _, a in p.a[i0..i1] {
if a != 0xff{
return false
}
}
i0+=p.as_tride
i1+=p.as_tride
}
return true
}

// NewNYCbCrA returns a new [NYCbCrA] image with the given bounds and subsample
// ratio.
pub fn new_nyc_b_cr_a(r Rectangle,subsample_ratio YCbCrSubsampleRatio) &NYCbCrA {
mut w, h, cw, ch:=y_cb_cr_size(r, subsample_ratio)
mut total_length:=add2_non_neg(mul3_non_neg(2, w, h), mul3_non_neg(2, cw, ch))
if total_length < 0{
panic('image: NewNYCbCrA Rectangle has huge or negative dimension')
}
mut i0:=1 * w * h + 0 * cw * ch
mut i1:=1 * w * h + 1 * cw * ch
mut i2:=1 * w * h + 2 * cw * ch
mut i3:=2 * w * h + 2 * cw * ch
mut b:=[]u8{len: i3}
return &NYCbCrA{
	yc_b_cr: YCbCr{
	y: b[..i0]
	cb: b[i0..i1]
	cr: b[i1..i2]
	subsample_ratio: subsample_ratio
	ys_tride: w
	cs_tride: cw
	rect: r
}
	a: b[i2..]
	as_tride: w
}
}
