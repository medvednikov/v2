module image

import io
import sync
// ErrFormat indicates that decoding encountered an unknown format.
__global err_format = errors.new('image: unknown format')
// A format holds an image format's name, magic header and how to decode it.
struct Format {
pub mut:
	name string
	magic string
	decode fn(io.Reader) (Image,IError) = unsafe { nil }
	decode_config fn(io.Reader) (Config,IError) = unsafe { nil }
}

// Formats is the list of registered formats.
__global formats_mu sync.Mutex
__global atomic_formats atomic.Value

// RegisterFormat registers an image format for use by [Decode].
// Name is the name of the format, like "jpeg" or "png".
// Magic is the magic prefix that identifies the format's encoding. The magic
// string can contain "?" wildcards that each match any one byte.
// [Decode] is the function that decodes the encoded image.
// [DecodeConfig] is the function that decodes just its configuration.
pub fn register_format(name string,magic string,decode fn(io.Reader) (Image,IError),decode_config fn(io.Reader) (Config,IError)) {
formats_mu.lock()
mut formats := atomic_formats.load() as []Format
atomic_formats.store(append(formats, Format{
name
magic
decode
decode_config
}))
formats_mu.unlock()
}
// A reader is an io.Reader that can also peek ahead.
interface reader {
	peek(isize) ([]u8,IError)
}


// asReader converts an io.Reader to a reader.
fn as_reader(r io.Reader) Reader {
mut ok := r is Reader
mut rr := r as Reader
if ok{
return rr
}
return bufio.new_reader(r)
}

// match reports whether magic matches b. Magic may contain "?" wildcards.
fn match_(magic string,b []u8) bool {
if magic.len != b.len{
return false
}
for i, c in b {
if magic[i] != c && magic[i] != `?`{
return false
}
}
return true
}

// sniff determines the format of r's data.
fn sniff(r Reader) Format {
mut formats := atomic_formats.load() as []Format
for _, f in formats {
mut b, err:=r.peek(f.magic.len)
if err == unsafe { nil } && match_(f.magic, b){
return f
}
}
return Format{}
}

// Decode decodes an image that has been encoded in a registered format.
// The string returned is the format name used during format registration.
// Format registration is typically done by an init function in the codec-
// specific package.
pub fn decode(r io.Reader) (Image,string,IError) {
mut rr:=as_reader(r)
mut f:=sniff(rr)
if f.decode == unsafe { nil }{
return unsafe { nil }, '', err_format
}
mut m, err:=f.decode(rr)
return m, f.name, err
}

// DecodeConfig decodes the color model and dimensions of an image that has
// been encoded in a registered format. The string returned is the format name
// used during format registration. Format registration is typically done by
// an init function in the codec-specific package.
pub fn decode_config(r io.Reader) (Config,string,IError) {
mut rr:=as_reader(r)
mut f:=sniff(rr)
if f.decode_config == unsafe { nil }{
return Config{}, '', err_format
}
mut c, err:=f.decode_config(rr)
return c, f.name, err
}
