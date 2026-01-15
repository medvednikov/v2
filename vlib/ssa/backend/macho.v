module backend

import encoding.binary
	import os

// Mach-O Constants for ARM64
const (
	mh_magic_64 = 0xfeedfacf
	cpu_type_arm64 = 0x0100000c
	cpu_subtype_arm64_all = 0
	
	lc_segment_64 = 0x19
	lc_symtab     = 0x2
	lc_dysymtab   = 0xb
	
	prot_read    = 1
	prot_write   = 2
	prot_execute = 4

	n_sect_text = 1
	n_sect_data = 2 // If we split
	
	// Relocations
	arm64_reloc_unsigned      = 0
	arm64_reloc_branch26      = 2
	arm64_reloc_page21        = 3
	arm64_reloc_pageoff12     = 4
	arm64_reloc_got_load_page21 = 5
	arm64_reloc_got_load_pageoff12 = 6
	arm64_reloc_addend        = 10
)

pub struct MachOObject {
pub mut:
	text_data []u8
	str_data  []u8 // cstrings
	
	relocs    []RelocationInfo
	symbols   []Symbol
	str_table []u8 // symbol names
}

struct RelocationInfo {
	addr      int
	sym_idx   int
	pcrel     bool
	length    int // 2 for 4 bytes
	extern    bool
	type_     int
}

struct Symbol {
	name    string
	type_   u8
	sect    u8
	desc    u16
	value   u64
}

pub fn MachOObject.new() &MachOObject {
	mut m := &MachOObject{
		str_table: [u8(0)] // Start with null byte
	}
	return m
}

pub fn (mut m MachOObject) add_symbol(name string, addr u64, is_ext bool, sect u8) int {
	idx := m.symbols.len
	
	// Add name to str_table
	name_off := m.str_table.len
	m.str_table << name.bytes()
	m.str_table << 0
	
	typ := if is_ext { u8(0x0f) } else { u8(0x0e) } // N_SECT | N_EXT : N_SECT
	
	m.symbols << Symbol{
		name:  name
		type_: typ
		sect:  sect
		desc:  0
		value: addr
	}
	
	// If it's the symbol table entry, we actually need to store the str_table offset in the struct
	// We handle serialization later.
	return idx
}

pub fn (mut m MachOObject) add_undefined(name string) int {
	// Check duplicates
	for i, s in m.symbols {
		if s.name == name && s.type_ == 0x01 { return i }
	}
	
	idx := m.symbols.len
	name_off := m.str_table.len
	m.str_table << name.bytes()
	m.str_table << 0
	
	m.symbols << Symbol{
		name:  name
		type_: 0x01 // N_UNDF | N_EXT
		sect:  0
		desc:  0
		value: 0
	}
	return idx
}

pub fn (mut m MachOObject) add_reloc(addr int, sym_idx int, typ int, pcrel bool) {
	m.relocs << RelocationInfo{
		addr:    addr
		sym_idx: sym_idx
		type_:   typ
		pcrel:   pcrel
		length:  2 // log2(4) = 2
		extern:  true // Assuming mostly external or symbol based
	}
}

pub fn (mut m MachOObject) write(path string) {
	mut buf := []u8{}
	
	// Offsets calculation
	header_size := 32
	// Load Commands: Segment64 (Text+CString), SymTab
	// Segment64: 72 + (80 * n_sects)
	n_sects := 2 // __text, __cstring
	seg_cmd_size := 72 + (80 * n_sects)
	symtab_cmd_size := 24
	
	load_cmds_size := seg_cmd_size + symtab_cmd_size
	
	// Data offsets
	text_off := header_size + load_cmds_size
	text_len := m.text_data.len
	
	cstring_off := text_off + text_len
	cstring_len := m.str_data.len
	
	// Padding for alignment (optional but good)
	// Relocations come after data
	reloc_off := cstring_off + cstring_len
	reloc_len := m.relocs.len * 8
	
	sym_off := reloc_off + reloc_len
	sym_len := m.symbols.len * 16
	
	str_off := sym_off + sym_len
	str_size := m.str_table.len
	
	// 1. Mach Header
	buf.write_u32_le(mh_magic_64)
	buf.write_u32_le(cpu_type_arm64)
	buf.write_u32_le(cpu_subtype_arm64_all)
	buf.write_u32_le(1) // filetype: MH_OBJECT
	buf.write_u32_le(2) // ncmds
	buf.write_u32_le(load_cmds_size) // sizeofcmds
	buf.write_u32_le(0) // flags
	buf.write_u32_le(0) // reserved
	
	// 2. Segment Command 64 (Unnamed for Object files usually, or empty)
	buf.write_u32_le(lc_segment_64)
	buf.write_u32_le(seg_cmd_size)
	for _ in 0..16 { buf << 0 } // segname
	buf.write_u64_le(0) // vmaddr
	buf.write_u64_le(u64(text_len + cstring_len)) // vmsize
	buf.write_u64_le(u64(text_off)) // fileoff
	buf.write_u64_le(u64(text_len + cstring_len)) // filesize
	buf.write_u32_le(7) // maxprot (rwx)
	buf.write_u32_le(7) // initprot
	buf.write_u32_le(n_sects) // nsects
	buf.write_u32_le(0) // flags
	
	// Section 1: __text
	buf.write_string_fixed("__text", 16)
	buf.write_string_fixed("__TEXT", 16)
	buf.write_u64_le(0) // addr
	buf.write_u64_le(u64(text_len)) // size
	buf.write_u32_le(text_off) // offset
	buf.write_u32_le(4) // align (2^4 = 16)
	buf.write_u32_le(reloc_off) // reloff
	buf.write_u32_le(m.relocs.len) // nreloc
	buf.write_u32_le(0x80000400) // flags (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)
	buf.write_u32_le(0) // reserved1
	buf.write_u32_le(0) // reserved2
	buf.write_u32_le(0) // reserved3
	
	// Section 2: __cstring
	buf.write_string_fixed("__cstring", 16)
	buf.write_string_fixed("__TEXT", 16)
	buf.write_u64_le(u64(text_len)) // addr starts after text
	buf.write_u64_le(u64(cstring_len)) // size
	buf.write_u32_le(cstring_off) // offset
	buf.write_u32_le(0) // align
	buf.write_u32_le(0) // reloff
	buf.write_u32_le(0) // nreloc
	buf.write_u32_le(2) // flags (S_CSTRING_LITERALS)
	buf.write_u32_le(0) // reserved1
	buf.write_u32_le(0) // reserved2
	buf.write_u32_le(0) // reserved3

	// 3. SymTab Command
	buf.write_u32_le(lc_symtab)
	buf.write_u32_le(symtab_cmd_size)
	buf.write_u32_le(sym_off)
	buf.write_u32_le(m.symbols.len)
	buf.write_u32_le(str_off)
	buf.write_u32_le(str_size)
	
	// 4. Data: Text
	buf << m.text_data
	
	// 5. Data: CString
	buf << m.str_data
	
	// 6. Relocations
	for r in m.relocs {
		// r_address (int32)
		buf.write_u32_le(r.addr)
		// bitfields: symbolnum(24), pcrel(1), length(2), extern(1), type(4)
		mut info := u32(r.sym_idx)
		if r.pcrel { info |= (1 << 24) }
		info |= (u32(r.length) << 25)
		if r.extern { info |= (1 << 27) }
		info |= (u32(r.type_) << 28)
		buf.write_u32_le(info)
	}
	
	// 7. Symbols
	// Need to recalc string table offsets
	mut current_str_off := 0
	for s in m.symbols {
		buf.write_u32_le(current_str_off) // n_strx
		current_str_off += s.name.len + 1
		
		buf << s.type_
		buf << s.sect
		buf.write_u16_le(s.desc)
		buf.write_u64_le(s.value)
	}
	
	// 8. String Table
	buf << m.str_table
	
	os.write_file_array(path, buf) or { panic(err) }
}

fn (mut b []u8) write_u32_le(v int) {
	b << u8(v)
	b << u8(v >> 8)
	b << u8(v >> 16)
	b << u8(v >> 24)
}

fn (mut b []u8) write_u64_le(v u64) {
	b << u8(v)
	b << u8(v >> 8)
	b << u8(v >> 16)
	b << u8(v >> 24)
	b << u8(v >> 32)
	b << u8(v >> 40)
	b << u8(v >> 48)
	b << u8(v >> 56)
}

fn (mut b []u8) write_u16_le(v u16) {
	b << u8(v)
	b << u8(v >> 8)
}

fn (mut b []u8) write_string_fixed(s string, len int) {
	mut bytes := s.bytes()
	for bytes.len < len { bytes << 0 }
	for i in 0..len { b << bytes[i] }
}
