module image

import image.color
import math.bits
import strconv
// A Point is an X, Y coordinate pair. The axes increase right and down.
pub struct Point {
pub mut:
	x isize
	y isize
}


// String returns a string representation of p like "(3,4)".
pub fn (p Point) str() string {
return '('+strconv.itoa(p.x)+',' + strconv.itoa(p.y)+')'
}

// Add returns the vector p+q.
pub fn (p Point) add(q Point) Point {
return Point{
p.x + q.x
p.y + q.y
}
}

// Sub returns the vector p-q.
pub fn (p Point) sub(q Point) Point {
return Point{
p.x - q.x
p.y - q.y
}
}

// Mul returns the vector p*k.
pub fn (p Point) mul(k isize) Point {
return Point{
p.x * k
p.y * k
}
}

// Div returns the vector p/k.
pub fn (p Point) div(k isize) Point {
return Point{
p.x / k
p.y / k
}
}

// In reports whether p is in r.
pub fn (p Point) in_(r Rectangle) bool {
return r.min.x <= p.x && p.x < r.max.x && r.min.y <= p.y && p.y < r.max.y
}

// Mod returns the point q in r such that p.X-q.X is a multiple of r's width
// and p.Y-q.Y is a multiple of r's height.
pub fn (p Point) mod(r Rectangle) Point {
mut w, h:=r.dx(), r.dy()
p=p.sub(r.min)
p.x=p.x % w
if p.x < 0{
p.x+=w
}
p.y=p.y % h
if p.y < 0{
p.y+=h
}
return p.add(r.min)
}

// Eq reports whether p and q are equal.
pub fn (p Point) eq(q Point) bool {
return p == q
}
// ZP is the zero [Point].
//
// Deprecated: Use a literal [image.Point] instead.
__global zp Point

// Pt is shorthand for [Point]{X, Y}.
pub fn pt(x isize,y isize) Point {
return Point{
x
y
}
}
// A Rectangle contains the points with Min.X <= X < Max.X, Min.Y <= Y < Max.Y.
// It is well-formed if Min.X <= Max.X and likewise for Y. Points are always
// well-formed. A rectangle's methods always return well-formed outputs for
// well-formed inputs.
//
// A Rectangle is also an [Image] whose bounds are the rectangle itself. At
// returns color.Opaque for points in the rectangle and color.Transparent
// otherwise.
pub struct Rectangle {
pub mut:
	min Point
	max Point
}


// String returns a string representation of r like "(3,4)-(6,5)".
pub fn (r Rectangle) str_1() string {
return r.min.str()+'-' + r.max.str()
}

// Dx returns r's width.
pub fn (r Rectangle) dx() isize {
return r.max.x - r.min.x
}

// Dy returns r's height.
pub fn (r Rectangle) dy() isize {
return r.max.y - r.min.y
}

// Size returns r's width and height.
pub fn (r Rectangle) size() Point {
return Point{
r.max.x - r.min.x
r.max.y - r.min.y
}
}

// Add returns the rectangle r translated by p.
pub fn (r Rectangle) add_1(p Point) Rectangle {
return Rectangle{
Point{
r.min.x + p.x
r.min.y + p.y
}
Point{
r.max.x + p.x
r.max.y + p.y
}
}
}

// Sub returns the rectangle r translated by -p.
pub fn (r Rectangle) sub_1(p Point) Rectangle {
return Rectangle{
Point{
r.min.x - p.x
r.min.y - p.y
}
Point{
r.max.x - p.x
r.max.y - p.y
}
}
}

// Inset returns the rectangle r inset by n, which may be negative. If either
// of r's dimensions is less than 2*n then an empty rectangle near the center
// of r will be returned.
pub fn (r Rectangle) inset(n isize) Rectangle {
if r.dx() < 2 * n{
r.min.x=(r.min.x + r.max.x) / 2
r.max.x=r.min.x
}
else
{
r.min.x+=n
r.max.x-=n
}
if r.dy() < 2 * n{
r.min.y=(r.min.y + r.max.y) / 2
r.max.y=r.min.y
}
else
{
r.min.y+=n
r.max.y-=n
}
return r
}

// Intersect returns the largest rectangle contained by both r and s. If the
// two rectangles do not overlap then the zero rectangle will be returned.
pub fn (r Rectangle) intersect(s Rectangle) Rectangle {
if r.min.x < s.min.x{
r.min.x=s.min.x
}
if r.min.y < s.min.y{
r.min.y=s.min.y
}
if r.max.x > s.max.x{
r.max.x=s.max.x
}
if r.max.y > s.max.y{
r.max.y=s.max.y
}
if r.empty(){
return Rectangle{}
}
return r
}

// Union returns the smallest rectangle that contains both r and s.
pub fn (r Rectangle) union(s Rectangle) Rectangle {
if r.empty(){
return s
}
if s.empty(){
return r
}
if r.min.x > s.min.x{
r.min.x=s.min.x
}
if r.min.y > s.min.y{
r.min.y=s.min.y
}
if r.max.x < s.max.x{
r.max.x=s.max.x
}
if r.max.y < s.max.y{
r.max.y=s.max.y
}
return r
}

// Empty reports whether the rectangle contains no points.
pub fn (r Rectangle) empty() bool {
return r.min.x >= r.max.x || r.min.y >= r.max.y
}

// Eq reports whether r and s contain the same set of points. All empty
// rectangles are considered equal.
pub fn (r Rectangle) eq_1(s Rectangle) bool {
return r == s || r.empty() && s.empty()
}

// Overlaps reports whether r and s have a non-empty intersection.
pub fn (r Rectangle) overlaps(s Rectangle) bool {
return !r.empty() && !s.empty() && r.min.x < s.max.x && s.min.x < r.max.x && r.min.y < s.max.y && s.min.y < r.max.y
}

// In reports whether every point in r is in s.
pub fn (r Rectangle) in__1(s Rectangle) bool {
if r.empty(){
return true
}
return s.min.x <= r.min.x && r.max.x <= s.max.x && s.min.y <= r.min.y && r.max.y <= s.max.y
}

// Canon returns the canonical version of r. The returned rectangle has minimum
// and maximum coordinates swapped if necessary so that it is well-formed.
pub fn (r Rectangle) canon() Rectangle {
if r.max.x < r.min.x{
r.min.x, r.max.x=r.max.x, r.min.x
}
if r.max.y < r.min.y{
r.min.y, r.max.y=r.max.y, r.min.y
}
return r
}

// At implements the [Image] interface.
pub fn (r Rectangle) at(x isize,y isize) color.Color {
if (Point{
x
y
}).in_(r){
return color.opaque
}
return color.transparent
}

// RGBA64At implements the [RGBA64Image] interface.
pub fn (r Rectangle) rgba_64_at(x isize,y isize) color.RGBA64 {
if (Point{
x
y
}).in_(r){
return color.RGBA64{
0xffff
0xffff
0xffff
0xffff
}
}
return color.RGBA64{}
}

// Bounds implements the [Image] interface.
pub fn (r Rectangle) bounds() Rectangle {
return r
}

// ColorModel implements the [Image] interface.
pub fn (r Rectangle) color_model() color.Model {
return color.alpha16_model
}
// ZR is the zero [Rectangle].
//
// Deprecated: Use a literal [image.Rectangle] instead.
__global zr Rectangle

// Rect is shorthand for [Rectangle]{Pt(x0, y0), [Pt](x1, y1)}. The returned
// rectangle has minimum and maximum coordinates swapped if necessary so that
// it is well-formed.
pub fn rect(x0 isize,y0 isize,x1 isize,y1 isize) Rectangle {
if x0 > x1{
x0, x1=x1, x0
}
if y0 > y1{
y0, y1=y1, y0
}
return Rectangle{
Point{
x0
y0
}
Point{
x1
y1
}
}
}

// mul3NonNeg returns (x * y * z), unless at least one argument is negative or
// if the computation overflows the int type, in which case it returns -1.
fn mul3_non_neg(x isize,y isize,z isize) isize {
if (x < 0) || (y < 0) || (z < 0){
return -1
}
mut hi, lo:=bits.mul64(u64(x), u64(y))
if hi != 0{
return -1
}
hi, lo=bits.mul64(lo, u64(z))
if hi != 0{
return -1
}
mut a:=isize(lo)
if (a < 0) || (u64(a) != lo){
return -1
}
return a
}

// add2NonNeg returns (x + y), unless at least one argument is negative or if
// the computation overflows the int type, in which case it returns -1.
fn add2_non_neg(x isize,y isize) isize {
if (x < 0) || (y < 0){
return -1
}
mut a:=x + y
if a < 0{
return -1
}
return a
}
