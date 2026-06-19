module pref

import os

pub struct Preferences {
pub mut:
	verbose      bool
	building_v   bool
	output_file  string
	target_os    string = os.user_os()
	target_arch  string = host_arch()
	user_defines []string
	backend      string = 'c'
	vroot        string = detect_vroot()
}

pub fn new_preferences() &Preferences {
	return &Preferences{}
}

pub fn host_arch() string {
	$if amd64 {
		return 'amd64'
	} $else $if i386 {
		return 'i386'
	} $else $if arm64 {
		return 'arm64'
	} $else $if arm32 {
		return 'arm32'
	} $else $if rv64 {
		return 'rv64'
	} $else $if rv32 {
		return 'rv32'
	} $else $if s390x {
		return 's390x'
	} $else $if ppc64le {
		return 'ppc64le'
	} $else $if loongarch64 {
		return 'loongarch64'
	} $else {
		if sizeof(voidptr) == 8 {
			return 'amd64'
		}
		return 'i386'
	}
}

pub fn normalized_arch(arch string) string {
	a := arch.to_lower()
	if a == '' || a == '_auto' || a == 'auto' {
		return host_arch()
	}
	return match a {
		'amd64', 'x86_64', 'x64', 'x86' { 'amd64' }
		'aarch64', 'arm64' { 'arm64' }
		'aarch32', 'arm32', 'arm' { 'arm32' }
		'rv64', 'riscv64', 'risc-v64', 'riscv', 'risc-v' { 'rv64' }
		'rv32', 'riscv32', 'risc-v32' { 'rv32' }
		'x86_32', 'x32', 'i386', 'ia-32', 'ia32' { 'i386' }
		else { a }
	}
}

pub fn target_int_bits(arch string) int {
	return match normalized_arch(arch) {
		'arm32', 'rv32', 'i386', 'ppc', 'wasm32' { 32 }
		else { 64 }
	}
}

pub fn (p &Preferences) int_bits() int {
	return target_int_bits(p.target_arch)
}

fn detect_vroot() string {
	baked_root := @VMODROOT
	if baked_root.len > 0 {
		return baked_root
	}
	if os.args.len > 0 && os.args[0].len > 0 {
		vroot := detect_vroot_from(os.args[0])
		if vroot.len > 0 {
			return vroot
		}
	}
	return detect_vroot_from(os.getwd())
}

fn detect_vroot_from(start string) string {
	if start.len == 0 {
		return ''
	}
	mut dir := start
	if !os.is_abs_path(dir) {
		cwd := os.getwd()
		if cwd.len > 0 {
			dir = os.join_path_single(cwd, dir)
		}
	}
	if !os.is_dir(dir) {
		dir = os.dir(dir)
	}
	for _ in 0 .. 8 {
		if os.is_dir(os.join_path_single(os.join_path_single(dir, 'vlib'), 'builtin')) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return ''
}

pub fn (p &Preferences) get_vlib_module_path(mod string) string {
	mod_path := mod.replace('.', os.path_separator)
	return os.join_path_single(os.join_path_single(p.vroot, 'vlib'), mod_path)
}

pub fn (p &Preferences) get_module_path(mod string, importing_file_path string) string {
	mod_path := mod.replace('.', os.path_separator)
	relative_path := os.join_path_single(os.dir(importing_file_path), mod_path)
	if os.is_dir(relative_path) {
		return relative_path
	}
	vlib_path := os.join_path_single(os.join_path_single(p.vroot, 'vlib'), mod_path)
	if os.is_dir(vlib_path) {
		return vlib_path
	}
	return ''
}

pub fn file_has_incompatible_os_suffix(file string, current_os string) bool {
	os_name := normalized_os(current_os)
	if os_name == 'windows' && file.contains('_nix.') {
		return true
	}
	if os_name != 'windows' && file.contains('_windows.') {
		return true
	}
	if os_name != 'linux' && file.contains('_linux.') {
		return true
	}
	if os_name != 'macos' && (file.contains('_macos.') || file.contains('_darwin.')) {
		return true
	}
	if os_name != 'macos' && os_name != 'freebsd' && os_name != 'openbsd' && os_name != 'netbsd'
		&& os_name != 'dragonfly' && file.contains('_bsd.') {
		return true
	}
	if os_name != 'android' && file.contains('_android') {
		return true
	}
	if os_name != 'ios' && file.contains('_ios.') {
		return true
	}
	if os_name != 'freebsd' && file.contains('_freebsd.') {
		return true
	}
	if os_name != 'openbsd' && file.contains('_openbsd.') {
		return true
	}
	if os_name != 'netbsd' && file.contains('_netbsd.') {
		return true
	}
	if os_name != 'dragonfly' && file.contains('_dragonfly.') {
		return true
	}
	if os_name != 'solaris' && file.contains('_solaris.') {
		return true
	}
	if file.contains('.amd64.') || file.contains('_amd64.') || file.contains('.arm64.')
		|| file.contains('_arm64.') {
		return true
	}
	return false
}

pub fn get_v_files_from_dir(dir string, user_defines []string, target_os string) []string {
	if dir == '' || !os.is_dir(dir) {
		return []string{}
	}
	all_files := os.ls(dir) or { return []string{} }
	mut v_files := []string{}
	for file in all_files {
		if !file.ends_with('.v') || file.ends_with('.js.v') || file.contains('_test.') {
			continue
		}
		if file_has_incompatible_os_suffix(file, target_os) {
			continue
		}
		if file.contains('_notd_') {
			feature := extract_define_feature(file, '_notd_')
			if feature.len > 0 && feature in user_defines {
				continue
			}
		} else if file.contains('_d_') {
			feature := extract_define_feature(file, '_d_')
			if feature.len == 0 || feature !in user_defines {
				continue
			}
		}
		v_files << os.join_path_single(dir, file)
	}
	return v_files
}

fn extract_define_feature(file string, marker string) string {
	idx := file.index(marker) or { return '' }
	rest := file[idx + marker.len..]
	if rest.ends_with('.c.v') {
		return rest[..rest.len - 4]
	}
	if rest.ends_with('.v') {
		return rest[..rest.len - 2]
	}
	return rest
}

pub fn normalized_os(target_os string) string {
	return match target_os {
		'darwin' { 'macos' }
		'mac' { 'macos' }
		else { target_os }
	}
}

pub fn (p &Preferences) normalized_target_os() string {
	return normalized_os(p.target_os)
}

pub fn (p &Preferences) is_cross_target() bool {
	return p.normalized_target_os() != normalized_os(os.user_os())
}

pub fn comptime_flag_value(p &Preferences, name string) bool {
	match name {
		'macos', 'darwin', 'mac' {
			return p.normalized_target_os() == 'macos'
		}
		'linux' {
			return p.normalized_target_os() == 'linux'
		}
		'windows' {
			return p.normalized_target_os() == 'windows'
		}
		'freebsd' {
			return p.normalized_target_os() == 'freebsd'
		}
		'openbsd' {
			return p.normalized_target_os() == 'openbsd'
		}
		'netbsd' {
			return p.normalized_target_os() == 'netbsd'
		}
		'dragonfly' {
			return p.normalized_target_os() == 'dragonfly'
		}
		'android' {
			return p.normalized_target_os() == 'android'
		}
		'posix', 'unix' {
			return p.normalized_target_os() != 'windows'
		}
		'bsd' {
			tos := p.normalized_target_os()
			return tos == 'macos' || tos == 'freebsd' || tos == 'openbsd' || tos == 'netbsd'
				|| tos == 'dragonfly'
		}
		'x64', 'amd64' {
			$if amd64 {
				return true
			}
			return false
		}
		'arm64', 'aarch64' {
			$if arm64 {
				return true
			}
			return false
		}
		'little_endian' {
			$if little_endian {
				return true
			}
			return false
		}
		'big_endian' {
			$if big_endian {
				return true
			}
			return false
		}
		'debug' {
			$if debug {
				return true
			}
			return false
		}
		'native' {
			return p.backend == 'arm64'
		}
		'builtin_write_buf_to_fd_should_use_c_write' {
			return p.backend == 'arm64'
		}
		'tinyc' {
			return p.backend == 'arm64'
		}
		'no_backtrace' {
			return p.backend == 'arm64' || name in p.user_defines
		}
		'gcboehm', 'gcboehm_opt' {
			if p.building_v {
				return false
			}
			return name in p.user_defines
		}
		'prealloc', 'autofree', 'no_bounds_checking', 'freestanding',
		'nofloat' {
			return name in p.user_defines
		}
		else {
			return name in p.user_defines
		}
	}
}

pub fn comptime_optional_flag_value(p &Preferences, name string) bool {
	if name in p.user_defines {
		return true
	}
	return comptime_flag_value(p, name)
}

pub fn comptime_pkgconfig_value(name string) bool {
	result := os.execute('pkg-config --exists ${name}')
	return result.exit_code == 0
}
