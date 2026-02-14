module image

import image.color
__global black = new_uniform(color.black)
__global white = new_uniform(color.white)
__global transparent = new_uniform(color.transparent)
__global opaque = new_uniform(color.opaque)
// Uniform is an infinite-sized [Image] of uniform color.
// It implements the [color.Color], [color.Model], and [Image] interfaces.
pub struct Uniform {
pub mut:
	c color.Color
}


pub fn (mut c Uniform) rgba() u32 {
mut r:=0
mut g:=0
mut b:=0
mut a:=0
return c.c.rgba()
}

pub fn (mut c Uniform) color_model() color.Model {
return c
}

pub fn (mut c Uniform) convert(_ color.Color) color.Color {
return c.c
}

pub fn (mut c Uniform) bounds() Rectangle {
return Rectangle{
Point{
-1e9
-1e9
}
Point{
1e9
1e9
}
}
}

pub fn (mut c Uniform) at(x isize,y isize) color.Color {
return c.c
}

pub fn (mut c Uniform) rgba_64_at(x isize,y isize) color.RGBA64 {
mut r, g, b, a:=c.c.rgba()
return color.RGBA64{
u16(r)
u16(g)
u16(b)
u16(a)
}
}

// Opaque scans the entire image and reports whether it is fully opaque.
pub fn (mut c Uniform) opaque() bool {
_, _, _, a:=c.c.rgba()
return a == 0xffff
}

// NewUniform returns a new [Uniform] image of the given color.
pub fn new_uniform(c color.Color) &Uniform {
return &Uniform{
c
}
}
