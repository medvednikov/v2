module imageutil

import image

// DrawYCbCr draws the YCbCr source image on the RGBA destination image with
// r.Min in dst aligned with sp in src. It reports whether the draw was
// successful. If it returns false, no dst pixels were changed.
//
// This function assumes that r is entirely within dst's bounds and the
// translation of r from dst coordinate space to src coordinate space is
// entirely within src's bounds.
pub fn draw_yc_b_cr(dst &image.RGBA,r image.Rectangle,src &image.YCbCr,sp image.Point) bool {
mut ok:=false
mut x0:=(r.min.x - dst.rect.min.x) * 4
mut x1:=(r.max.x - dst.rect.min.x) * 4
mut y0:=r.min.y - dst.rect.min.y
mut y1:=r.max.y - dst.rect.min.y
match src.subsample_ratio{
image.yc_b_cr_subsample_ratio444{
for y, sy:=y0, sp.y
; y != y1; y, sy=y+1, sy+1
{
mut dpix:=dst.pix[y * dst.stride..]
mut yi:=(sy - src.rect.min.y) * src.ys_tride + (sp.x - src.rect.min.x)
mut ci:=(sy - src.rect.min.y) * src.cs_tride + (sp.x - src.rect.min.x)
for x:=x0
; x != x1; x, yi, ci=x+4, yi+1, ci+1
{
mut yy1:=i32(src.y[yi]) * 0x10101
mut cb1:=i32(src.cb[ci]) - 128
mut cr1:=i32(src.cr[ci]) - 128
mut r_1:=yy1 + 91881 * cr1
if u32(r_1) & 0xff000000 == 0{
r>>=16
}
else
{
r=~(r_1 >> 31)
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
mut rgba:=dpix[x..x+4]
rgba[0]=u8(r_1)
rgba[1]=u8(g)
rgba[2]=u8(b)
rgba[3]=255
}
}
}
image.yc_b_cr_subsample_ratio422{
for y, sy:=y0, sp.y
; y != y1; y, sy=y+1, sy+1
{
mut dpix_1:=dst.pix[y * dst.stride..]
mut yi_1:=(sy - src.rect.min.y) * src.ys_tride + (sp.x - src.rect.min.x)
mut ci_base:=(sy - src.rect.min.y) * src.cs_tride - src.rect.min.x / 2
for x, sx:=x0, sp.x
; x != x1; x, sx, yi=x+4, sx+1, yi_1+1
{
mut ci_1:=ci_base + sx / 2
mut yy1_1:=i32(src.y[yi_1]) * 0x10101
mut cb1_1:=i32(src.cb[ci_1]) - 128
mut cr1_1:=i32(src.cr[ci_1]) - 128
mut r_2:=yy1_1 + 91881 * cr1_1
if u32(r_2) & 0xff000000 == 0{
r>>=16
}
else
{
r=~(r_2 >> 31)
}
mut g_1:=yy1_1 - 22554 * cb1_1 - 46802 * cr1_1
if u32(g_1) & 0xff000000 == 0{
g>>=16
}
else
{
g=~(g_1 >> 31)
}
mut b_1:=yy1_1 + 116130 * cb1_1
if u32(b_1) & 0xff000000 == 0{
b>>=16
}
else
{
b=~(b_1 >> 31)
}
mut rgba_1:=dpix_1[x..x+4]
rgba_1[0]=u8(r_2)
rgba_1[1]=u8(g_1)
rgba_1[2]=u8(b_1)
rgba_1[3]=255
}
}
}
image.yc_b_cr_subsample_ratio420{
for y, sy:=y0, sp.y
; y != y1; y, sy=y+1, sy+1
{
mut dpix_2:=dst.pix[y * dst.stride..]
mut yi_2:=(sy - src.rect.min.y) * src.ys_tride + (sp.x - src.rect.min.x)
mut ci_base_1:=(sy / 2 - src.rect.min.y / 2) * src.cs_tride - src.rect.min.x / 2
for x, sx:=x0, sp.x
; x != x1; x, sx, yi=x+4, sx+1, yi_2+1
{
mut ci_2:=ci_base_1 + sx / 2
mut yy1_2:=i32(src.y[yi_2]) * 0x10101
mut cb1_2:=i32(src.cb[ci_2]) - 128
mut cr1_2:=i32(src.cr[ci_2]) - 128
mut r_3:=yy1_2 + 91881 * cr1_2
if u32(r_3) & 0xff000000 == 0{
r>>=16
}
else
{
r=~(r_3 >> 31)
}
mut g_2:=yy1_2 - 22554 * cb1_2 - 46802 * cr1_2
if u32(g_2) & 0xff000000 == 0{
g>>=16
}
else
{
g=~(g_2 >> 31)
}
mut b_2:=yy1_2 + 116130 * cb1_2
if u32(b_2) & 0xff000000 == 0{
b>>=16
}
else
{
b=~(b_2 >> 31)
}
mut rgba_2:=dpix_2[x..x+4]
rgba_2[0]=u8(r_3)
rgba_2[1]=u8(g_2)
rgba_2[2]=u8(b_2)
rgba_2[3]=255
}
}
}
image.yc_b_cr_subsample_ratio440{
for y, sy:=y0, sp.y
; y != y1; y, sy=y+1, sy+1
{
mut dpix_3:=dst.pix[y * dst.stride..]
mut yi_3:=(sy - src.rect.min.y) * src.ys_tride + (sp.x - src.rect.min.x)
mut ci_3:=(sy / 2 - src.rect.min.y / 2) * src.cs_tride + (sp.x - src.rect.min.x)
for x:=x0
; x != x1; x, yi, ci=x+4, yi_3+1, ci_3+1
{
mut yy1_3:=i32(src.y[yi_3]) * 0x10101
mut cb1_3:=i32(src.cb[ci_3]) - 128
mut cr1_3:=i32(src.cr[ci_3]) - 128
mut r_4:=yy1_3 + 91881 * cr1_3
if u32(r_4) & 0xff000000 == 0{
r>>=16
}
else
{
r=~(r_4 >> 31)
}
mut g_3:=yy1_3 - 22554 * cb1_3 - 46802 * cr1_3
if u32(g_3) & 0xff000000 == 0{
g>>=16
}
else
{
g=~(g_3 >> 31)
}
mut b_3:=yy1_3 + 116130 * cb1_3
if u32(b_3) & 0xff000000 == 0{
b>>=16
}
else
{
b=~(b_3 >> 31)
}
mut rgba_3:=dpix_3[x..x+4]
rgba_3[0]=u8(r_4)
rgba_3[1]=u8(g_3)
rgba_3[2]=u8(b_3)
rgba_3[3]=255
}
}
}
else {
return false
}
}
return true
}
