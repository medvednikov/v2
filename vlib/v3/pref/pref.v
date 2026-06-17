module pref

import os

pub struct Preferences {
pub mut:
	verbose      bool
	output_file  string
	target_os    string = os.user_os()
	user_defines []string
pub:
	vroot string = detect_vroot()
}

pub fn new_preferences() &Preferences {
	return &Preferences{}
}

fn detect_vroot() string {
	if os.args.len > 0 && os.args[0].len > 0 {
		mut dir := os.dir(os.args[0])
		if !os.is_abs_path(dir) {
			cwd := os.getwd()
			if cwd.len > 0 {
				dir = os.join_path(cwd, dir)
			}
		}
		for _ in 0 .. 8 {
			if os.is_dir(os.join_path(dir, 'vlib', 'builtin')) {
				return dir
			}
			parent := os.dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	cwd := os.getwd()
	if os.is_dir(os.join_path(cwd, 'vlib', 'builtin')) {
		return cwd
	}
	return ''
}

pub fn (p &Preferences) get_vlib_module_path(mod string) string {
	mod_path := mod.replace('.', os.path_separator)
	return os.join_path(p.vroot, 'vlib', mod_path)
}

pub fn (p &Preferences) get_module_path(mod string, importing_file_path string) string {
	mod_path := mod.replace('.', os.path_separator)
	relative_path := os.join_path(os.dir(importing_file_path), mod_path)
	if os.is_dir(relative_path) {
		return relative_path
	}
	vlib_path := os.join_path(p.vroot, 'vlib', mod_path)
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
	if os_name !in ['macos', 'freebsd', 'openbsd', 'netbsd', 'dragonfly'] && file.contains('_bsd.') {
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
		v_files << os.join_path(dir, file)
	}
	v_files.sort()
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

pub fn comptime_flag_value(pref &Preferences, name string) bool {
	match name {
		'macos', 'darwin', 'mac' {
			return pref.normalized_target_os() == 'macos'
		}
		'linux' {
			return pref.normalized_target_os() == 'linux'
		}
		'windows' {
			return pref.normalized_target_os() == 'windows'
		}
		'freebsd' {
			return pref.normalized_target_os() == 'freebsd'
		}
		'openbsd' {
			return pref.normalized_target_os() == 'openbsd'
		}
		'netbsd' {
			return pref.normalized_target_os() == 'netbsd'
		}
		'dragonfly' {
			return pref.normalized_target_os() == 'dragonfly'
		}
		'android' {
			return pref.normalized_target_os() == 'android'
		}
		'posix', 'unix' {
			return pref.normalized_target_os() != 'windows'
		}
		'bsd' {
			return pref.normalized_target_os() in ['macos', 'freebsd', 'openbsd', 'netbsd',
				'dragonfly']
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
		'gcboehm', 'gcboehm_opt', 'prealloc', 'autofree', 'no_bounds_checking', 'freestanding',
		'nofloat' {
			return name in pref.user_defines
		}
		else {
			return name in pref.user_defines
		}
	}
}

pub fn comptime_optional_flag_value(pref &Preferences, name string) bool {
	if name in pref.user_defines {
		return true
	}
	return comptime_flag_value(pref, name)
}

pub fn comptime_pkgconfig_value(name string) bool {
	result := os.execute('pkg-config --exists ${name}')
	return result.exit_code == 0
}
