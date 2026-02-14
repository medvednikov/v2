module jpeg

import io
// maxCodeLength is the maximum (inclusive) number of bits in a Huffman code.
const max_code_length = 16
// maxNCodes is the maximum (inclusive) number of codes in a Huffman tree.
const max_nc_odes = 256
// lutSize is the log-2 size of the Huffman decoder's look-up table.
const lut_size = 8
// huffman is a Huffman decoder, specified in section C.
struct Huffman {
pub mut:
// length is the number of codes in the tree.
	n_codes i32
// lut is the look-up table for the next lutSize bits in the bit-stream.
// The high 8 bits of the uint16 are the encoded value. The low 8 bits
// are 1 plus the code length, or 0 if the value is too large to fit in
// lutSize bits.
	lut [1 << LutSize]u16
// vals are the decoded values, sorted by their encoding.
	vals [MaxNCodes]u8
// minCodes[i] is the minimum code of length i, or -1 if there are no
// codes of that length.
	min_codes [MaxCodeLength]i32
// maxCodes[i] is the maximum code of length i, or -1 if there are no
// codes of that length.
	max_codes [MaxCodeLength]i32
// valsIndices[i] is the index into vals of minCodes[i].
	vals_indices [MaxCodeLength]i32
}

// errShortHuffmanData means that an unexpected EOF occurred while decoding
// Huffman data.
__global err_short_huffman_data = format_error('short Huffman data')

// ensureNBits reads bytes from the byte buffer to ensure that d.bits.n is at
// least n. For best performance (avoiding function calls inside hot loops),
// the caller is the one responsible for first checking that d.bits.n < n.
fn (mut d Decoder) ensure_nb_its(n i32) IError {
for {
mut c, err:=d.read_byte_stuffed_byte()
if err != unsafe { nil }{
if err == io.err_unexpected_eof{
return err_short_huffman_data
}
return err
}
d.bits.a=d.bits.a << 8 | u32(c)
d.bits.n+=8
if d.bits.m == 0{
d.bits.m=1 << 7
}
else
{
d.bits.m<<=8
}
if d.bits.n >= n{
break
}
}
return unsafe { nil }
}

// receiveExtend is the composition of RECEIVE and EXTEND, specified in section
// F.2.2.1.
fn (mut d Decoder) receive_extend(t u8) (i32,IError) {
if d.bits.n < i32(t){
mut err:=d.ensure_nb_its(i32(t))
if err != unsafe { nil }{
return 0, err
}
}
d.bits.n-=i32(t)
d.bits.m>>=t
mut s:=i32(1) << t
mut x:=i32(d.bits.a >> u8(d.bits.n)) & (s - 1)
if x < s >> 1{
x+=((-1) << t)+1
}
return x, unsafe { nil }
}

// processDHT processes a Define Huffman Table marker, and initializes a huffman
// struct from its contents. Specified in section B.2.4.2.
fn (mut d Decoder) process_dht(n isize) IError {
for n > 0{
if n < 17{
return format_error('DHT has wrong length')
}
mut err:=d.read_full(d.tmp[..17])
if err != unsafe { nil }{
return err
}
mut tc:=d.tmp[0] >> 4
if tc > max_tc{
return format_error('bad Tc value')
}
mut th:=d.tmp[0] & 0x0f
if th > max_th || (d.baseline && th > 1){
return format_error('bad Th value')
}
mut h:=&d.huff[tc][th]
h.n_codes=0
mut n_codes := [max_code_length]i32{}

for i,  _  in n_codes {
n_codes[i]=i32(d.tmp[i+1])
h.n_codes+=n_codes[i]
}
if h.n_codes == 0{
return format_error('Huffman table has zero length')
}
if h.n_codes > max_nc_odes{
return format_error('Huffman table has excessive length')
}
n-=isize(h.n_codes)+17
if n < 0{
return format_error('DHT has wrong length')
}
mut err_1:=d.read_full(h.vals[..h.n_codes])
if err_1 != unsafe { nil }{
return err_1
}
clear(h.lut[..])
mut x,code := 0

for i_1:=u32(0)
; i_1 < lut_size; i_1++
{
code<<=1
for j:=i32(0)
; j < n_codes[i_1]; j++
{
mut base:=u8(code << (7 - i_1))
mut lut_value:=u16(h.vals[x]) << 8 | u16(2+i_1)
for k:=u8(0)
; k < 1 << (7 - i_1); k++
{
h.lut[base | k]=lut_value
}
code++
x++
}
}
mut c,index := 0

for i, n_1 in n_codes {
if n_1 == 0{
h.min_codes[i_1]=-1
h.max_codes[i_1]=-1
h.vals_indices[i_1]=-1
}
else
{
h.min_codes[i_1]=c
h.max_codes[i_1]=c + n_1 - 1
h.vals_indices[i_1]=index
c+=n_1
index+=n_1
}
c<<=1
}
}
return unsafe { nil }
}

// decodeHuffman returns the next Huffman-coded value from the bit-stream,
// decoded according to h.
fn (mut d Decoder) decode_huffman(h &Huffman) (u8,IError) {
if h.n_codes == 0{
return 0, format_error('uninitialized Huffman table')
}
if d.bits.n < 8{
mut err:=d.ensure_nb_its(8)
if err != unsafe { nil }{
if err != err_missing_ff_00 && err != err_short_huffman_data{
return 0, err
}
if d.bytes.n_unreadable != 0{
d.unread_byte_stuffed_byte()
}
goto slowPath
}
}
mut v:=h.lut[(d.bits.a >> u32(d.bits.n - lut_size)) & 0xff]
if v != 0{
mut n:=(v & 0xff) - 1
d.bits.n-=i32(n)
d.bits.m>>=n
return u8(v >> 8), unsafe { nil }
}
slowPath:
for i, code:=isize(0), i32(0)
; i < max_code_length; i++
{
if d.bits.n == 0{
mut err_1:=d.ensure_nb_its(1)
if err_1 != unsafe { nil }{
return 0, err_1
}
}
if d.bits.a & d.bits.m != 0{
code|=1
}
d.bits.n--
d.bits.m>>=1
if code <= h.max_codes[i]{
return h.vals[h.vals_indices[i] + code - h.min_codes[i]], unsafe { nil }
}
code<<=1
}
return 0, format_error('bad Huffman code')
}

fn (mut d Decoder) decode_bit() (bool,IError) {
if d.bits.n == 0{
mut err:=d.ensure_nb_its(1)
if err != unsafe { nil }{
return false, err
}
}
mut ret:=d.bits.a & d.bits.m != 0
d.bits.n--
d.bits.m>>=1
return ret, unsafe { nil }
}

fn (mut d Decoder) decode_bits(n i32) (u32,IError) {
if d.bits.n < n{
mut err:=d.ensure_nb_its(n)
if err != unsafe { nil }{
return 0, err
}
}
mut ret:=d.bits.a >> u32(d.bits.n - n)
ret&=(1 << u32(n)) - 1
d.bits.n-=n
d.bits.m>>=u32(n)
return ret, unsafe { nil }
}
