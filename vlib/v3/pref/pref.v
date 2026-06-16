module pref

import os

pub struct Preferences {
pub mut:
	verbose      bool
	output_file  string
	target_os    string = os.user_os()
	user_defines []string
}

pub fn new_preferences() &Preferences {
	return &Preferences{}
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
