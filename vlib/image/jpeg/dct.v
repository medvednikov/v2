module jpeg


// dctBox implements a 3-multiply, 3-add rotation+scaling.
// Given x0, x1, k*cos θ, and k*sin θ, dctBox returns the
// rotated and scaled coordinates.
// (It is called dctBox because the rotate+scale operation
// is drawn as a box in Figures 1 and 2 in the paper.)
fn dct_box(x0 i32,x1 i32,kcos i32,ksin i32) i32 {
mut y0:=0
mut y1:=0
mut ksum:=kcos * (x0 + x1)
y0=ksum + (ksin - kcos) * x1
y1=ksum - (kcos + ksin) * x0
return y0, y1
}
// A block is an 8x8 input to a 2D DCT (either the FDCT or IDCT).
// The input is actually only 8x8 uint8 values, and the outputs are 8x8 int16,
// but it is convenient to use int32s for intermediate storage,
// so we define only a single block type of [8*8]int32.
//
// A 2D DCT is implemented as 1D DCTs over the rows and columns.
//
// dct_test.go defines a String method for nice printing in tests.
type Block = [BlockSize]i32
const block_size = 8 * 8
// Constants needed for the implementation.
// These are all 60-bit precision fixed-point constants.
// The function c(val, b) rounds the constant to b bits.
// c is simple enough that calls to it with constant args
// are inlined and constant-propagated down to an inline constant.
// Each constant is commented with its Ivy definition (see robpike.io/ivy),
// using this scaling helper function:
//
//	op fix x = floor 0.5 + x * 2**60
const cos1 = 1130768441178740757
const sin1 = 224923827593068887
const cos3 = 958619196450722178
const sin3 = 640528868967736374
const sqrt2 = 1630477228166597777
const sqrt2_cos6 = 623956622067911264
const sqrt2_sin6 = 1506364539328854985
const sqrt2inv = 815238614083298888
const sqrt2inv_cos6 = 311978311033955632
const sqrt2inv_sin6 = 753182269664427492

fn c(x u64,bits isize) i32 {
return i32((x + (1 << (59 - bits))) >> (60 - bits))
}

// fdct implements the forward DCT.
// Inputs are UQ8.0; outputs are Q13.0.
fn fdct(b &Block) {
fdct_cols(b)
fdct_rows(b)
}

// fdctCols applies the 1D DCT to the columns of b.
// Inputs are UQ8.0 in [0,255] but interpreted as [-128,127].
// Outputs are Q10.18.
fn fdct_cols(b &Block) {
for i,  _  in 8 {
mut x0:=b[0 * 8 + i]
mut x1:=b[1 * 8 + i]
mut x2:=b[2 * 8 + i]
mut x3:=b[3 * 8 + i]
mut x4:=b[4 * 8 + i]
mut x5:=b[5 * 8 + i]
mut x6:=b[6 * 8 + i]
mut x7:=b[7 * 8 + i]
x0, x7=x0 + x7, x0 - x7
x1, x6=x1 + x6, x1 - x6
x2, x5=x2 + x5, x2 - x5
x3, x4=x3 + x4, x3 - x4
x4, x7=dct_box(x4, x7, c(cos3, 18), c(sin3, 18))
x5, x6=dct_box(x5, x6, c(cos1, 18), c(sin1, 18))
x0, x3=x0 + x3, x0 - x3
x1, x2=x1 + x2, x1 - x2
x2, x3=dct_box(x2, x3, c(sqrt2_cos6, 18), c(sqrt2_sin6, 18))
x0, x1=x0 + x1, x0 - x1
b[0 * 8 + i]=(x0 - 128 * 8) << 18
b[4 * 8 + i]=x1 << 18
b[2 * 8 + i]=x2
b[6 * 8 + i]=x3
x4, x6=x4 + x6, x4 - x6
x7, x5=x7 + x5, x7 - x5
x5=(x5 >> 12) * c(sqrt2, 12)
x6=(x6 >> 12) * c(sqrt2, 12)
x7, x4=x7 + x4, x7 - x4
b[1 * 8 + i]=x7
b[3 * 8 + i]=x5
b[5 * 8 + i]=x6
b[7 * 8 + i]=x4
}
}

// fdctRows applies the 1D DCT to the rows of b.
// Inputs are Q10.18; outputs are Q13.0.
fn fdct_rows(b &Block) {
for i,  _  in 8 {
mut x:=b[8 * i..8 * i+8]
mut x0:=x[0]
mut x1:=x[1]
mut x2:=x[2]
mut x3:=x[3]
mut x4:=x[4]
mut x5:=x[5]
mut x6:=x[6]
mut x7:=x[7]
x0, x7=x0 + x7, x0 - x7
x1, x6=x1 + x6, x1 - x6
x2, x5=x2 + x5, x2 - x5
x3, x4=x3 + x4, x3 - x4
x4, x7=dct_box(x4 >> 14, x7 >> 14, c(cos3, 14), c(sin3, 14))
x5, x6=dct_box(x5 >> 14, x6 >> 14, c(cos1, 14), c(sin1, 14))
x0, x3=x0 + x3, x0 - x3
x1, x2=x1 + x2, x1 - x2
x2, x3=dct_box(x2 >> 14, x3 >> 14, c(sqrt2_cos6, 14), c(sqrt2_sin6, 14))
x0, x1=x0 + x1, x0 - x1
x4, x6=x4 + x6, x4 - x6
x7, x5=x7 + x5, x7 - x5
x5=(x5 >> 14) * c(sqrt2, 14)
x6=(x6 >> 14) * c(sqrt2, 14)
x7, x4=x7 + x4, x7 - x4
x0=(x0 + 1 << 17) >> 18
x1=(x1 + 1 << 17) >> 18
x2=(x2 + 1 << 17) >> 18
x3=(x3 + 1 << 17) >> 18
x4=(x4 + 1 << 17) >> 18
x5=(x5 + 1 << 17) >> 18
x6=(x6 + 1 << 17) >> 18
x7=(x7 + 1 << 17) >> 18
x[0]=x0
x[1]=x7
x[2]=x2
x[3]=x5
x[4]=x1
x[5]=x6
x[6]=x3
x[7]=x4
}
}

// idct implements the inverse DCT.
// Inputs are UQ8.0; outputs are Q10.3.
fn idct(b &Block) {
idct_rows(b)
idct_cols(b)
}

// idctRows applies the 1D IDCT to the rows of b.
// Inputs are UQ8.0; outputs are Q9.20.
fn idct_rows(b &Block) {
for i,  _  in 8 {
mut x:=b[8 * i..8 * i+8]
mut x0:=x[0]
mut x7:=x[1]
mut x2:=x[2]
mut x5:=x[3]
mut x1:=x[4]
mut x6:=x[5]
mut x3:=x[6]
mut x4:=x[7]
x0<<=17
x1<<=17
x0, x1=x0 + x1, x0 - x1
x2, x3=dct_box(x2, x3, c(sqrt2inv_cos6, 18), -c(sqrt2inv_sin6, 18))
x1, x2=x1 + x2, x1 - x2
x0, x3=x0 + x3, x0 - x3
x4<<=7
x7<<=7
x7, x4=x7 + x4, x7 - x4
x6=x6 * c(sqrt2inv, 8)
x5=x5 * c(sqrt2inv, 8)
x7, x5=x7 + x5, x7 - x5
x4, x6=x4 + x6, x4 - x6
x4, x7=dct_box(x4 >> 2, x7 >> 2, c(cos3, 12), -c(sin3, 12))
x5, x6=dct_box(x5 >> 2, x6 >> 2, c(cos1, 12), -c(sin1, 12))
x0, x7=x0 + x7, x0 - x7
x1, x6=x1 + x6, x1 - x6
x2, x5=x2 + x5, x2 - x5
x3, x4=x3 + x4, x3 - x4
x[0]=x0
x[1]=x1
x[2]=x2
x[3]=x3
x[4]=x4
x[5]=x5
x[6]=x6
x[7]=x7
}
}

// idctCols applies the 1D IDCT to the columns of b.
// Inputs are Q9.20.
// Outputs are Q10.3. That is, the result is the IDCT*8.
fn idct_cols(b &Block) {
for i,  _  in 8 {
mut x0:=b[0 * 8 + i]
mut x7:=b[1 * 8 + i]
mut x2:=b[2 * 8 + i]
mut x5:=b[3 * 8 + i]
mut x1:=b[4 * 8 + i]
mut x6:=b[5 * 8 + i]
mut x3:=b[6 * 8 + i]
mut x4:=b[7 * 8 + i]
x0+=1 << 19
x0, x1=(x0 + x1) >> 2, (x0 - x1) >> 2
x2, x3=dct_box(x2 >> 13, x3 >> 13, c(sqrt2inv_cos6, 12), -c(sqrt2inv_sin6, 12))
x1, x2=x1 + x2, x1 - x2
x0, x3=x0 + x3, x0 - x3
x7, x4=x7 + x4, x7 - x4
x5=(x5 >> 13) * c(sqrt2inv, 14)
x6=(x6 >> 13) * c(sqrt2inv, 14)
x7, x5=x7 + x5, x7 - x5
x4, x6=x4 + x6, x4 - x6
x4, x7=dct_box(x4 >> 14, x7 >> 14, c(cos3, 12), -c(sin3, 12))
x5, x6=dct_box(x5 >> 14, x6 >> 14, c(cos1, 12), -c(sin1, 12))
x0, x7=x0 + x7, x0 - x7
x1, x6=x1 + x6, x1 - x6
x2, x5=x2 + x5, x2 - x5
x3, x4=x3 + x4, x3 - x4
x0>>=18
x1>>=18
x2>>=18
x3>>=18
x4>>=18
x5>>=18
x6>>=18
x7>>=18
b[0 * 8 + i]=x0
b[1 * 8 + i]=x1
b[2 * 8 + i]=x2
b[3 * 8 + i]=x3
b[4 * 8 + i]=x4
b[5 * 8 + i]=x5
b[6 * 8 + i]=x6
b[7 * 8 + i]=x7
}
}
