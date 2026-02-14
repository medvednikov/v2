module png

// intSize is either 32 or 64.
const int_size = 32 << (~usize(0) >> 63)

fn abs(x isize) isize {
mut m:=x >> (int_size - 1)
return (x ^ m) - m
}

// paeth implements the Paeth filter function, as per the PNG specification.
fn paeth(a u8,b u8,c u8) u8 {
mut pc:=isize(c)
mut pa:=isize(b) - pc
mut pb:=isize(a) - pc
pc=abs(pa + pb)
pa=abs(pa)
pb=abs(pb)
if pa <= pb && pa <= pc{
return a
}
else
if pb <= pc{
return b
}
return c
}

// filterPaeth applies the Paeth filter to the cdat slice.
// cdat is the current row's data, pdat is the previous row's data.
fn filter_paeth(cdat []u8,pdat []u8,bytes_per_pixel isize) {
mut a,b,c,pa,pb,pc := 0

for i:=isize(0)
; i < bytes_per_pixel; i++
{
a, c=0, 0
for j:=i
; j < cdat.len; j+=bytes_per_pixel
{
b=isize(pdat[j])
pa=b - c
pb=a - c
pc=abs(pa + pb)
pa=abs(pa)
pb=abs(pb)
if pa <= pb && pa <= pc{
}
else
if pb <= pc{
a=b
}
else
{
a=c
}
a+=isize(cdat[j])
a&=0xff
cdat[j]=u8(a)
c=b
}
}
}
