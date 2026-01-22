module backend

fn write_u32_le(mut b []u8, v u32) {
	b << u8(v)
	b << u8(v >> 8)
	b << u8(v >> 16)
	b << u8(v >> 24)
}

fn write_u64_le(mut b []u8, v u64) {
	b << u8(v)
	b << u8(v >> 8)
	b << u8(v >> 16)
	b << u8(v >> 24)
	b << u8(v >> 32)
	b << u8(v >> 40)
	b << u8(v >> 48)
	b << u8(v >> 56)
}

fn write_u16_le(mut b []u8, v u16) {
	b << u8(v)
	b << u8(v >> 8)
}

fn write_string_fixed(mut b []u8, s string, len int) {
	mut bytes := s.bytes()
	for bytes.len < len {
		bytes << 0
	}
	for i in 0 .. len {
		b << bytes[i]
	}
}
