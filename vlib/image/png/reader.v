module png

import compress.zlib
import encoding.binary
import hash
import hash.crc32
import image
import image.color
import io
// Color type, as per the PNG spec.
const ct_grayscale = 0
const ct_true_color = 2
const ct_paletted = 3
const ct_grayscale_alpha = 4
const ct_true_color_alpha = 6
// A cb is a combination of color type and bit depth.
enum CbInvalidEnum {
cb_invalid
cb_g1
cb_g2
cb_g4
cb_g8
cb_ga_8
cb_tc_8
cb_p1
cb_p2
cb_p4
cb_p8
cb_tca_8
cb_g16
cb_ga_16
cb_tc_16
cb_tca_16
}

fn cb_paletted(cb isize) bool {
return int(.cb_p1) <= int(cb) && int(cb) <= int(.cb_p8)
}

fn cb_true_color(cb isize) bool {
return cb == .cb_tc_8 || cb == .cb_tc_16
}
// Filter type, as per the PNG spec.
const ft_none = 0
const ft_sub = 1
const ft_up = 2
const ft_average = 3
const ft_paeth = 4
const n_filter = 5
// Interlace type.
const it_none = 0
const it_adam7 = 1
// interlaceScan defines the placement and size of a pass for Adam7 interlacing.
struct InterlaceScan {
pub mut:
	x_factor isize
	y_factor isize
	x_offset isize
	y_offset isize
}

// interlacing defines Adam7 interlacing, with 7 passes of reduced images.
// See https://www.w3.org/TR/PNG/#8Interlace
__global interlacing = [InterlaceScan{8, 8, 0, 0},InterlaceScan{8, 8, 4, 0},InterlaceScan{4, 8, 0, 4},InterlaceScan{4, 4, 2, 0},InterlaceScan{2, 4, 0, 2},InterlaceScan{2, 2, 1, 0},InterlaceScan{1, 2, 0, 1}]
// Decoding stage.
// The PNG specification says that the IHDR, PLTE (if present), tRNS (if
// present), IDAT and IEND chunks must appear in that order. There may be
// multiple IDAT chunks, and IDAT chunks must be sequential (i.e. they may not
// have any other chunks between them).
// https://www.w3.org/TR/PNG/#5ChunkOrdering
enum DsStartEnum {
DsStart
ds_seen_ihdr
ds_seen_plte
ds_seent_rns
ds_seen_idat
ds_seen_iend
}
const png_header = "\x89PNG\r\n\x1a\n"
struct Decoder {
pub mut:
	r io.Reader
	img image.Image
	crc hash.Hash32
	width isize
	height isize
	depth isize
	palette color.Palette
	cb isize
	stage isize
	idat_length u32
	tmp [3 * 256]u8
	interlace isize
// useTransparent and transparent are used for grayscale and truecolor
// transparency, as opposed to palette transparency.
	use_transparent bool
	transparent [6]u8
}

// A FormatError reports that the input is not a valid PNG.
type FormatError = string

pub fn (e FormatError) error_() string {
return 'png: invalid format: '+e.str()

}
__global chunk_order_error = format_error('chunk out of order')
// An UnsupportedError reports that the input uses a valid but unimplemented PNG feature.
type UnsupportedError = string

pub fn (e UnsupportedError) error__1() string {
return 'png: unsupported feature: '+e.str()

}

fn (mut d Decoder) parse_ihdr(length u32) IError {
if length != 13{
return format_error('bad IHDR length')
}
_, err:=io.read_full(d.r, d.tmp[..13])
if err != unsafe { nil }{
return err
}
d.crc.write(d.tmp[..13]) or { }
if d.tmp[10] != 0{
return unsupported_error('compression method')
}
if d.tmp[11] != 0{
return unsupported_error('filter method')
}
if d.tmp[12] != it_none && d.tmp[12] != it_adam7{
return format_error('invalid interlace method')
}
d.interlace=isize(d.tmp[12])
mut w:=i32(binary.big_endian_u32(d.tmp[0..4]))
mut h:=i32(binary.big_endian_u32(d.tmp[4..8]))
if w <= 0 || h <= 0{
return format_error('non-positive dimension')
}
mut n_pixels64:=i64(w) * i64(h)
mut n_pixels:=isize(n_pixels64)
if n_pixels64 != i64(n_pixels){
return unsupported_error('dimension overflow')
}
if n_pixels != (n_pixels * 8) / 8{
return unsupported_error('dimension overflow')
}
d.cb=.cb_invalid
d.depth=isize(d.tmp[8])
match d.depth{
1{
match d.tmp[9]{
ct_grayscale{
d.cb=.cb_g1
}
ct_paletted{
d.cb=.cb_p1
}
}
}
2{
match d.tmp[9]{
ct_grayscale{
d.cb=.cb_g2
}
ct_paletted{
d.cb=.cb_p2
}
}
}
4{
match d.tmp[9]{
ct_grayscale{
d.cb=.cb_g4
}
ct_paletted{
d.cb=.cb_p4
}
}
}
8{
match d.tmp[9]{
ct_grayscale{
d.cb=.cb_g8
}
ct_true_color{
d.cb=.cb_tc_8
}
ct_paletted{
d.cb=.cb_p8
}
ct_grayscale_alpha{
d.cb=.cb_ga_8
}
ct_true_color_alpha{
d.cb=.cb_tca_8
}
}
}
16{
match d.tmp[9]{
ct_grayscale{
d.cb=.cb_g16
}
ct_true_color{
d.cb=.cb_tc_16
}
ct_grayscale_alpha{
d.cb=.cb_ga_16
}
ct_true_color_alpha{
d.cb=.cb_tca_16
}
}
}
}
if d.cb == .cb_invalid{
return unsupported_error('')
}
d.width, d.height=isize(w), isize(h)
return d.verify_checksum()
}

fn (mut d Decoder) parse_plte(length u32) IError {
mut np:=isize(length / 3)
if length % 3 != 0 || np <= 0 || np > 256 || np > 1 << usize(d.depth){
return format_error('bad PLTE length')
}
mut n, err:=io.read_full(d.r, d.tmp[..3 * np])
if err != unsafe { nil }{
return err
}
d.crc.write(d.tmp[..n]) or { }
match d.cb{
.cb_p1,.cb_p2,.cb_p4,.cb_p8{
d.palette=color.Palette{}
for i:=isize(0)
; i < np; i++
{
d.palette[i]=color.RGBA{
d.tmp[3 * i+0]
d.tmp[3 * i+1]
d.tmp[3 * i+2]
0xff
}
}
for i:=np
; i < 256; i++
{
d.palette[i]=color.RGBA{
0x00
0x00
0x00
0xff
}
}
d.palette=d.palette[..np]
}
.cb_tc_8,.cb_tca_8,.cb_tc_16,.cb_tca_16{
}
else {
return format_error('PLTE, color type mismatch')
}
}
return d.verify_checksum()
}

fn (mut d Decoder) parset_rns(length u32) IError {
match d.cb{
.cb_g1,.cb_g2,.cb_g4,.cb_g8,.cb_g16{
if length != 2{
return format_error('bad tRNS length')
}
mut n, err:=io.read_full(d.r, d.tmp[..length])
if err != unsafe { nil }{
return err
}
d.crc.write(d.tmp[..n]) or { }
copy(d.transparent[..], d.tmp[..length])
match d.cb{
.cb_g1{
d.transparent[1]*=0xff
}
.cb_g2{
d.transparent[1]*=0x55
}
.cb_g4{
d.transparent[1]*=0x11
}
}
d.use_transparent=true
}
.cb_tc_8,.cb_tc_16{
if length != 6{
return format_error('bad tRNS length')
}
mut n_1, err_1:=io.read_full(d.r, d.tmp[..length])
if err_1 != unsafe { nil }{
return err_1
}
d.crc.write(d.tmp[..n_1]) or { }
copy(d.transparent[..], d.tmp[..length])
d.use_transparent=true
}
.cb_p1,.cb_p2,.cb_p4,.cb_p8{
if length > 256{
return format_error('bad tRNS length')
}
mut n_2, err_2:=io.read_full(d.r, d.tmp[..length])
if err_2 != unsafe { nil }{
return err_2
}
d.crc.write(d.tmp[..n_2]) or { }
if d.palette.len < n_2{
d.palette=d.palette[..n_2]
}
for i:=isize(0)
; i < n_2; i++
{
mut rgba:=d.palette[i]
d.palette[i]=color.NRGBA{
rgba.r
rgba.g
rgba.b
d.tmp[i]
}
}
}
else {
return format_error('tRNS, color type mismatch')
}
}
return d.verify_checksum()
}

// Read presents one or more IDAT chunks as one continuous stream (minus the
// intermediate chunk headers and footers). If the PNG data looked like:
//
//	... len0 IDAT xxx crc0 len1 IDAT yy crc1 len2 IEND crc2
//
// then this reader presents xxxyy. For well-formed PNG data, the decoder state
// immediately before the first Read call is that d.r is positioned between the
// first IDAT and xxx, and the decoder state immediately after the last Read
// call is that d.r is positioned between yy and crc1.
pub fn (mut d Decoder) read(p []u8) (isize,IError) {
if p.len == 0{
return 0, unsafe { nil }
}
for d.idat_length == 0{
mut err:=d.verify_checksum()
if err != unsafe { nil }{
return 0, err
}
_, err_1:=io.read_full(d.r, d.tmp[..8])
if err_1 != unsafe { nil }{
return 0, err_1
}
d.idat_length=binary.big_endian_u32(d.tmp[..4])
if d.tmp[4..8].str()
 != 'IDAT'{
return 0, format_error('not enough pixel data')
}
d.crc.reset()
d.crc.write(d.tmp[4..8]) or { }
}
if isize(d.idat_length) < 0{
return 0, unsupported_error('IDAT chunk length overflow')
}
mut n, err_2:=d.r.read(p[..min(p.len, isize(d.idat_length))])
d.crc.write(p[..n]) or { }
d.idat_length-=u32(n)
return n, err_2
}

// decode decodes the IDAT data into an image.
fn (mut d Decoder) decode() (image.Image,IError) {
mut r, err:=zlib.new_reader(d)
if err != unsafe { nil }{
return unsafe { nil }, err
}
defer {
r.close()
}
mut img := image.Image{}

if d.interlace == it_none{
img, err=d.read_image_pass(r, 0, false)
if err != unsafe { nil }{
return unsafe { nil }, err
}
}
else
if d.interlace == it_adam7{
img, err=d.read_image_pass(unsafe { nil }, 0, true)
if err != unsafe { nil }{
return unsafe { nil }, err
}
for pass:=isize(0)
; pass < 7; pass++
{
mut image_pass, err_1:=d.read_image_pass(r, pass, false)
if err_1 != unsafe { nil }{
return unsafe { nil }, err_1
}
if image_pass != unsafe { nil }{
d.merge_pass_into(img, image_pass, pass)
}
}
}
mut n:=isize(0)
for i:=isize(0)
; n == 0 && err_1 == unsafe { nil }; i++
{
if i == 100{
return unsafe { nil }, io.err_no_progress
}
n, err=r.read(d.tmp[..1])
}
if err_1 != unsafe { nil } && err_1 != io.eof{
return unsafe { nil }, format_error(err_1.error_())
}
if n != 0 || d.idat_length != 0{
return unsafe { nil }, format_error('too much pixel data')
}
return img, unsafe { nil }
}

// readImagePass reads a single image pass, sized according to the pass number.
fn (mut d Decoder) read_image_pass(r io.Reader,pass isize,allocate_only bool) (image.Image,IError) {
mut bits_per_pixel:=isize(0)
mut pix_offset:=isize(0)
mut gray := unsafe { nil }mut Rgba := unsafe { nil }mut Paletted := unsafe { nil }mut Nrgba := unsafe { nil }mut Gray16 := unsafe { nil }mut Rgba64 := unsafe { nil }mut Nrgba64 := unsafe { nil }mut Img := image.Image{}

mut width, height:=d.width, d.height
if d.interlace == it_adam7 && !allocate_only{
mut p:=interlacing[pass]
width=(width - p.x_offset + p.x_factor - 1) / p.x_factor
height=(height - p.y_offset + p.y_factor - 1) / p.y_factor
if width == 0 || height == 0{
return unsafe { nil }, unsafe { nil }
}
}
match d.cb{
.cb_g1,.cb_g2,.cb_g4,.cb_g8{
bits_per_pixel=d.depth
if d.use_transparent{
nrgba=image.new_nrgba(image.rect(0, 0, width, height))
img=nrgba
}
else
{
gray=image.new_gray(image.rect(0, 0, width, height))
img=gray
}
}
.cb_ga_8{
bits_per_pixel=16
nrgba=image.new_nrgba(image.rect(0, 0, width, height))
img=nrgba
}
.cb_tc_8{
bits_per_pixel=24
if d.use_transparent{
nrgba=image.new_nrgba(image.rect(0, 0, width, height))
img=nrgba
}
else
{
rgba=image.new_rgba(image.rect(0, 0, width, height))
img=rgba
}
}
.cb_p1,.cb_p2,.cb_p4,.cb_p8{
bits_per_pixel=d.depth
paletted=image.new_paletted(image.rect(0, 0, width, height), d.palette)
img=paletted
}
.cb_tca_8{
bits_per_pixel=32
nrgba=image.new_nrgba(image.rect(0, 0, width, height))
img=nrgba
}
.cb_g16{
bits_per_pixel=16
if d.use_transparent{
nrgba64=image.new_nrgba_64(image.rect(0, 0, width, height))
img=nrgba64
}
else
{
gray16=image.new_gray16(image.rect(0, 0, width, height))
img=gray16
}
}
.cb_ga_16{
bits_per_pixel=32
nrgba64=image.new_nrgba_64(image.rect(0, 0, width, height))
img=nrgba64
}
.cb_tc_16{
bits_per_pixel=48
if d.use_transparent{
nrgba64=image.new_nrgba_64(image.rect(0, 0, width, height))
img=nrgba64
}
else
{
rgba64=image.new_rgba_64(image.rect(0, 0, width, height))
img=rgba64
}
}
.cb_tca_16{
bits_per_pixel=64
nrgba64=image.new_nrgba_64(image.rect(0, 0, width, height))
img=nrgba64
}
}
if allocate_only{
return img, unsafe { nil }
}
mut bytes_per_pixel:=(bits_per_pixel+7) / 8
mut row_size:=1+(i64(bits_per_pixel) * i64(width)+7) / 8
if row_size != i64(isize(row_size)){
return unsafe { nil }, unsupported_error('dimension overflow')
}
mut cr:=[]u8{len: row_size}
mut pr:=[]u8{len: row_size}
for y:=isize(0)
; y < height; y++
{
_, err:=io.read_full(r, cr)
if err != unsafe { nil }{
if err == io.eof || err == io.err_unexpected_eof{
return unsafe { nil }, format_error('not enough pixel data')
}
return unsafe { nil }, err
}
mut cdat:=cr[1..]
mut pdat:=pr[1..]
match cr[0]{
ft_none{
}
ft_sub{
for i:=bytes_per_pixel
; i < cdat.len; i++
{
cdat[i]+=cdat[i - bytes_per_pixel]
}
}
ft_up{
for i, p_1 in pdat {
cdat[i]+=p_1
}
}
ft_average{
for i_1:=isize(0)
; i_1 < bytes_per_pixel; i_1++
{
cdat[i_1]+=pdat[i_1] / 2
}
for i:=bytes_per_pixel
; i_1 < cdat.len; i_1++
{
cdat[i_1]+=u8((isize(cdat[i_1 - bytes_per_pixel]) + isize(pdat[i_1])) / 2)
}
}
ft_paeth{
filter_paeth(cdat, pdat, bytes_per_pixel)
}
else {
return unsafe { nil }, format_error('bad filter type')
}
}
match d.cb{
.cb_g1{
if d.use_transparent{
mut ty:=d.transparent[1]
for x:=isize(0)
; x < width; x+=8
{
mut b:=cdat[x / 8]
for x2:=isize(0)
; x2 < 8 && x + x2 < width; x2++
{
mut ycol:=(b >> 7) * 0xff
mut acol:=u8(0xff)
if ycol == ty{
acol=0x00
}
go2v_tmp_0 := color.NRGBA{
ycol
ycol
ycol
acol
}
nrgba.set_nrgba(x + x2, y, go2v_tmp_0)
b<<=1
}
}
}
else
{
for x:=isize(0)
; x < width; x+=8
{
mut b_1:=cdat[x / 8]
for x2:=isize(0)
; x2 < 8 && x + x2 < width; x2++
{
go2v_tmp_1 := color.Gray{
(b_1 >> 7) * 0xff
}
gray.set_gray(x + x2, y, go2v_tmp_1)
b<<=1
}
}
}
}
.cb_g2{
if d.use_transparent{
mut ty_1:=d.transparent[1]
for x:=isize(0)
; x < width; x+=4
{
mut b_2:=cdat[x / 4]
for x2:=isize(0)
; x2 < 4 && x + x2 < width; x2++
{
mut ycol_1:=(b_2 >> 6) * 0x55
mut acol_1:=u8(0xff)
if ycol_1 == ty_1{
acol=0x00
}
go2v_tmp_2 := color.NRGBA{
ycol_1
ycol_1
ycol_1
acol_1
}
nrgba.set_nrgba(x + x2, y, go2v_tmp_2)
b<<=2
}
}
}
else
{
for x:=isize(0)
; x < width; x+=4
{
mut b_3:=cdat[x / 4]
for x2:=isize(0)
; x2 < 4 && x + x2 < width; x2++
{
go2v_tmp_3 := color.Gray{
(b_3 >> 6) * 0x55
}
gray.set_gray(x + x2, y, go2v_tmp_3)
b<<=2
}
}
}
}
.cb_g4{
if d.use_transparent{
mut ty_2:=d.transparent[1]
for x:=isize(0)
; x < width; x+=2
{
mut b_4:=cdat[x / 2]
for x2:=isize(0)
; x2 < 2 && x + x2 < width; x2++
{
mut ycol_2:=(b_4 >> 4) * 0x11
mut acol_2:=u8(0xff)
if ycol_2 == ty_2{
acol=0x00
}
go2v_tmp_4 := color.NRGBA{
ycol_2
ycol_2
ycol_2
acol_2
}
nrgba.set_nrgba(x + x2, y, go2v_tmp_4)
b<<=4
}
}
}
else
{
for x:=isize(0)
; x < width; x+=2
{
mut b_5:=cdat[x / 2]
for x2:=isize(0)
; x2 < 2 && x + x2 < width; x2++
{
go2v_tmp_5 := color.Gray{
(b_5 >> 4) * 0x11
}
gray.set_gray(x + x2, y, go2v_tmp_5)
b<<=4
}
}
}
}
.cb_g8{
if d.use_transparent{
mut ty_3:=d.transparent[1]
for x:=isize(0)
; x < width; x++
{
mut ycol_3:=cdat[x]
mut acol_3:=u8(0xff)
if ycol_3 == ty_3{
acol=0x00
}
go2v_tmp_6 := color.NRGBA{
ycol_3
ycol_3
ycol_3
acol_3
}
nrgba.set_nrgba(x, y, go2v_tmp_6)
}
}
else
{
copy(gray.pix[pix_offset..], cdat)
pix_offset+=gray.stride
}
}
.cb_ga_8{
for x:=isize(0)
; x < width; x++
{
mut ycol_4:=cdat[2 * x+0]
go2v_tmp_7 := color.NRGBA{
ycol_4
ycol_4
ycol_4
cdat[2 * x+1]
}
nrgba.set_nrgba(x, y, go2v_tmp_7)
}
}
.cb_tc_8{
if d.use_transparent{
mut pix, i, j:=nrgba.pix, pix_offset, isize(0)
mut tr, tg, tb:=d.transparent[1], d.transparent[3], d.transparent[5]
for x:=isize(0)
; x < width; x++
{
mut r_1:=cdat[j+0]
mut g:=cdat[j+1]
mut b_6:=cdat[j+2]
mut a:=u8(0xff)
if r_1 == tr && g == tg && b_6 == tb{
a=0x00
}
pix[i_1+0]=r_1
pix[i_1+1]=g
pix[i_1+2]=b_6
pix[i_1+3]=a
i+=4
j+=3
}
pix_offset+=nrgba.stride
}
else
{
mut pix_1, i_2, j_1:=rgba.pix, pix_offset, isize(0)
for x:=isize(0)
; x < width; x++
{
pix_1[i_2+0]=cdat[j_1+0]
pix_1[i_2+1]=cdat[j_1+1]
pix_1[i_2+2]=cdat[j_1+2]
pix_1[i_2+3]=0xff
i+=4
j+=3
}
pix_offset+=rgba.stride
}
}
.cb_p1{
for x:=isize(0)
; x < width; x+=8
{
mut b_7:=cdat[x / 8]
for x2:=isize(0)
; x2 < 8 && x + x2 < width; x2++
{
mut idx:=b_7 >> 7
if paletted.palette.len <= isize(idx){
paletted.palette=paletted.palette[..isize(idx)+1]
}
paletted.set_color_index(x + x2, y, idx)
b<<=1
}
}
}
.cb_p2{
for x:=isize(0)
; x < width; x+=4
{
mut b_8:=cdat[x / 4]
for x2:=isize(0)
; x2 < 4 && x + x2 < width; x2++
{
mut idx_1:=b_8 >> 6
if paletted.palette.len <= isize(idx_1){
paletted.palette=paletted.palette[..isize(idx_1)+1]
}
paletted.set_color_index(x + x2, y, idx_1)
b<<=2
}
}
}
.cb_p4{
for x:=isize(0)
; x < width; x+=2
{
mut b_9:=cdat[x / 2]
for x2:=isize(0)
; x2 < 2 && x + x2 < width; x2++
{
mut idx_2:=b_9 >> 4
if paletted.palette.len <= isize(idx_2){
paletted.palette=paletted.palette[..isize(idx_2)+1]
}
paletted.set_color_index(x + x2, y, idx_2)
b<<=4
}
}
}
.cb_p8{
if paletted.palette.len != 256{
for x:=isize(0)
; x < width; x++
{
if paletted.palette.len <= isize(cdat[x]){
paletted.palette=paletted.palette[..isize(cdat[x])+1]
}
}
}
copy(paletted.pix[pix_offset..], cdat)
pix_offset+=paletted.stride
}
.cb_tca_8{
copy(nrgba.pix[pix_offset..], cdat)
pix_offset+=nrgba.stride
}
.cb_g16{
if d.use_transparent{
mut ty_4:=u16(d.transparent[0]) << 8 | u16(d.transparent[1])
for x:=isize(0)
; x < width; x++
{
mut ycol_5:=u16(cdat[2 * x+0]) << 8 | u16(cdat[2 * x+1])
mut acol_4:=u16(0xffff)
if ycol_5 == ty_4{
acol=0x0000
}
go2v_tmp_8 := color.NRGBA64{
ycol_5
ycol_5
ycol_5
acol_4
}
nrgba64.set_nrgba_64(x, y, go2v_tmp_8)
}
}
else
{
for x:=isize(0)
; x < width; x++
{
mut ycol_6:=u16(cdat[2 * x+0]) << 8 | u16(cdat[2 * x+1])
go2v_tmp_9 := color.Gray16{
ycol_6
}
gray16.set_gray16(x, y, go2v_tmp_9)
}
}
}
.cb_ga_16{
for x:=isize(0)
; x < width; x++
{
mut ycol_7:=u16(cdat[4 * x+0]) << 8 | u16(cdat[4 * x+1])
mut acol_5:=u16(cdat[4 * x+2]) << 8 | u16(cdat[4 * x+3])
go2v_tmp_10 := color.NRGBA64{
ycol_7
ycol_7
ycol_7
acol_5
}
nrgba64.set_nrgba_64(x, y, go2v_tmp_10)
}
}
.cb_tc_16{
if d.use_transparent{
mut tr_1:=u16(d.transparent[0]) << 8 | u16(d.transparent[1])
mut tg_1:=u16(d.transparent[2]) << 8 | u16(d.transparent[3])
mut tb_1:=u16(d.transparent[4]) << 8 | u16(d.transparent[5])
for x:=isize(0)
; x < width; x++
{
mut rcol:=u16(cdat[6 * x+0]) << 8 | u16(cdat[6 * x+1])
mut gcol:=u16(cdat[6 * x+2]) << 8 | u16(cdat[6 * x+3])
mut bcol:=u16(cdat[6 * x+4]) << 8 | u16(cdat[6 * x+5])
mut acol_6:=u16(0xffff)
if rcol == tr_1 && gcol == tg_1 && bcol == tb_1{
acol=0x0000
}
go2v_tmp_11 := color.NRGBA64{
rcol
gcol
bcol
acol_6
}
nrgba64.set_nrgba_64(x, y, go2v_tmp_11)
}
}
else
{
for x:=isize(0)
; x < width; x++
{
mut rcol_1:=u16(cdat[6 * x+0]) << 8 | u16(cdat[6 * x+1])
mut gcol_1:=u16(cdat[6 * x+2]) << 8 | u16(cdat[6 * x+3])
mut bcol_1:=u16(cdat[6 * x+4]) << 8 | u16(cdat[6 * x+5])
go2v_tmp_12 := color.RGBA64{
rcol_1
gcol_1
bcol_1
0xffff
}
rgba64.set_rgba_64(x, y, go2v_tmp_12)
}
}
}
.cb_tca_16{
for x:=isize(0)
; x < width; x++
{
mut rcol_2:=u16(cdat[8 * x+0]) << 8 | u16(cdat[8 * x+1])
mut gcol_2:=u16(cdat[8 * x+2]) << 8 | u16(cdat[8 * x+3])
mut bcol_2:=u16(cdat[8 * x+4]) << 8 | u16(cdat[8 * x+5])
mut acol_7:=u16(cdat[8 * x+6]) << 8 | u16(cdat[8 * x+7])
go2v_tmp_13 := color.NRGBA64{
rcol_2
gcol_2
bcol_2
acol_7
}
nrgba64.set_nrgba_64(x, y, go2v_tmp_13)
}
}
}
pr, cr=cr, pr
}
return img, unsafe { nil }
}

// mergePassInto merges a single pass into a full sized image.
fn (mut d Decoder) merge_pass_into(dst image.Image,src image.Image,pass isize) {
mut p:=interlacing[pass]
mut src_pix := []u8{}
mut dst_pix := []u8{}
mut stride := 0
mut rect := image.Rectangle{}
mut bytes_per_pixel := 0

mut target := dst
match dst.type_name() {
'Alpha'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=1
}
'Alpha16'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=2
}
'Gray'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=1
}
'Gray16'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=2
}
'NRGBA'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=4
}
'NRGBA64'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=8
}
'Paletted'{
mut source:=src
src_pix=source.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=1
if target.palette.len < source.palette.len{
target.palette=source.palette
}
}
'RGBA'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=4
}
'RGBA64'{
src_pix=src.pix
dst_pix, stride, rect=target.pix, target.stride, target.rect
bytes_per_pixel=8
}
}
mut s, bounds:=isize(0), src.bounds()
for y:=bounds.min.y
; y < bounds.max.y; y++
{
mut d_base:=(y * p.y_factor + p.y_offset - rect.min.y) * stride + (p.x_offset - rect.min.x) * bytes_per_pixel
for x:=bounds.min.x
; x < bounds.max.x; x++
{
mut d_1:=d_base + x * p.x_factor * bytes_per_pixel
copy(dst_pix[d_1..], src_pix[s..s + bytes_per_pixel])
s+=bytes_per_pixel
}
}
}

fn (mut d Decoder) parse_idat(length u32) IError {
mut err:=IError{}
d.idat_length=length
d.img, err=d.decode()
if err != unsafe { nil }{
return err
}
return d.verify_checksum()
}

fn (mut d Decoder) parse_iend(length u32) IError {
if length != 0{
return format_error('bad IEND length')
}
return d.verify_checksum()
}

fn (mut d Decoder) parse_chunk(config_only bool) IError {
_, err:=io.read_full(d.r, d.tmp[..8])
if err != unsafe { nil }{
return err
}
mut length:=binary.big_endian_u32(d.tmp[..4])
d.crc.reset()
d.crc.write(d.tmp[4..8]) or { }
match d.tmp[4..8].str()
{
'IHDR'{
if d.stage != .ds_start{
return chunk_order_error
}
d.stage=.ds_seen_ihdr
return d.parse_ihdr(length)
}
'PLTE'{
if d.stage != .ds_seen_ihdr{
return chunk_order_error
}
d.stage=.ds_seen_plte
return d.parse_plte(length)
}
'tRNS'{
if cb_paletted(d.cb){
if d.stage != .ds_seen_plte{
return chunk_order_error
}
}
else
if cb_true_color(d.cb){
if d.stage != .ds_seen_ihdr && d.stage != .ds_seen_plte{
return chunk_order_error
}
}
else
if d.stage != .ds_seen_ihdr{
return chunk_order_error
}
d.stage=.ds_seent_rns
return d.parset_rns(length)
}
'IDAT'{
if int(d.stage) < int(Stage.ds_seen_ihdr) || int(d.stage) > int(Stage.ds_seen_idat) || (d.stage == .ds_seen_ihdr && cb_paletted(d.cb)){
return chunk_order_error
}
else
if d.stage == .ds_seen_idat{
break
}
d.stage=.ds_seen_idat
if config_only{
return unsafe { nil }
}
return d.parse_idat(length)
}
'IEND'{
if d.stage != .ds_seen_idat{
return chunk_order_error
}
d.stage=.ds_seen_iend
return d.parse_iend(length)
}
}
if length > 0x7fffffff{
return format_error('')
}
mut ignored := [4096]u8{}

for length > 0{
mut n, err_1:=io.read_full(d.r, ignored[..min(ignored.len, isize(length))])
if err_1 != unsafe { nil }{
return err_1
}
d.crc.write(ignored[..n]) or { }
length-=u32(n)
}
return d.verify_checksum()
}

fn (mut d Decoder) verify_checksum() IError {
_, err:=io.read_full(d.r, d.tmp[..4])
if err != unsafe { nil }{
return err
}
if binary.big_endian_u32(d.tmp[..4]) != d.crc.sum32(){
return format_error('invalid checksum')
}
return unsafe { nil }
}

fn (mut d Decoder) check_header() IError {
_, err:=io.read_full(d.r, d.tmp[..png_header.len])
if err != unsafe { nil }{
return err
}
if d.tmp[..png_header.len].str()
 != png_header{
return format_error('not a PNG file')
}
return unsafe { nil }
}

// Decode reads a PNG image from r and returns it as an [image.Image].
// The type of Image returned depends on the PNG contents.
pub fn decode_1(r io.Reader) (image.Image,IError) {
mut d:=&Decoder{
	r: r
	crc: crc32.new_ieee()
}
mut err:=d.check_header()
if err != unsafe { nil }{
if err == io.eof{
err=io.err_unexpected_eof
}
return unsafe { nil }, err
}
for d.stage != .ds_seen_iend{
mut err_1:=d.parse_chunk(false)
if err_1 != unsafe { nil }{
if err_1 == io.eof{
err=io.err_unexpected_eof
}
return unsafe { nil }, err_1
}
}
return d.img, unsafe { nil }
}

// DecodeConfig returns the color model and dimensions of a PNG image without
// decoding the entire image.
pub fn decode_config(r io.Reader) (image.Config,IError) {
mut d:=&Decoder{
	r: r
	crc: crc32.new_ieee()
}
mut err:=d.check_header()
if err != unsafe { nil }{
if err == io.eof{
err=io.err_unexpected_eof
}
go2v_tmp_14 := image.Config{}
return go2v_tmp_14, err
}
for {
mut err_1:=d.parse_chunk(true)
if err_1 != unsafe { nil }{
if err_1 == io.eof{
err=io.err_unexpected_eof
}
go2v_tmp_15 := image.Config{}
return go2v_tmp_15, err_1
}
if cb_paletted(d.cb){
if int(d.stage) >= int(Stage.ds_seent_rns){
break
}
}
else
{
if int(d.stage) >= int(Stage.ds_seen_ihdr){
break
}
}
}
mut cm := color.Model{}

match d.cb{
.cb_g1,.cb_g2,.cb_g4,.cb_g8{
cm=color.gray_model
}
.cb_ga_8{
cm=color.nrgbam_odel
}
.cb_tc_8{
cm=color.rgbam_odel
}
.cb_p1,.cb_p2,.cb_p4,.cb_p8{
cm=d.palette
}
.cb_tca_8{
cm=color.nrgbam_odel
}
.cb_g16{
cm=color.gray16_model
}
.cb_ga_16{
cm=color.nrgba_64_model
}
.cb_tc_16{
cm=color.rgba_64_model
}
.cb_tca_16{
cm=color.nrgba_64_model
}
}
go2v_tmp_16 := image.Config{
	color_model: cm
	width: d.width
	height: d.height
}
return go2v_tmp_16, unsafe { nil }
}

fn init() {
image.register_format('png', png_header, decode, decode_config)
}
