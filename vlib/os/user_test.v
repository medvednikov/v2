module os

fn test_current_user() {
	user := current_user() or {
		assert false, 'current_user() failed: ${err}'
		return
	}
	assert user.username.len > 0
	assert user.home_dir.len > 0
	$if !windows {
		assert user.uid == u32(getuid())
		assert user.gid == u32(getgid())
	}
}

fn test_lookup_user() {
	$if !windows {
		// Look up root user (should exist on all Unix systems)
		root := lookup_user('root') or {
			assert false, 'lookup_user("root") failed: ${err}'
			return
		}
		assert root.username == 'root'
		assert root.uid == 0

		// Look up current user by name
		current := current_user() or {
			assert false, 'current_user() failed: ${err}'
			return
		}
		user := lookup_user(current.username) or {
			assert false, 'lookup_user("${current.username}") failed: ${err}'
			return
		}
		assert user.username == current.username
		assert user.uid == current.uid
	}
}

fn test_lookup_user_id() {
	$if !windows {
		// Look up root by UID
		root := lookup_user_id(0) or {
			assert false, 'lookup_user_id(0) failed: ${err}'
			return
		}
		assert root.uid == 0
		assert root.username == 'root'

		// Look up current user by UID
		current := current_user() or {
			assert false, 'current_user() failed: ${err}'
			return
		}
		user := lookup_user_id(current.uid) or {
			assert false, 'lookup_user_id(${current.uid}) failed: ${err}'
			return
		}
		assert user.uid == current.uid
		assert user.username == current.username
	}
}

fn test_lookup_user_not_found() {
	$if !windows {
		lookup_user('__nonexistent_user_12345__') or {
			assert err.msg().contains('not found')
			return
		}
		assert false, 'expected error for nonexistent user'
	}
}

fn test_lookup_group() {
	$if !windows {
		// Look up wheel or root group (should exist on most Unix systems)
		$if macos || darwin {
			grp := lookup_group('wheel') or {
				assert false, 'lookup_group("wheel") failed: ${err}'
				return
			}
			assert grp.name == 'wheel'
			assert grp.gid == 0
		} $else {
			grp := lookup_group('root') or {
				// Some systems might not have root group, try wheel
				lookup_group('wheel') or {
					// Skip test if neither exists
					return
				}
				return
			}
			assert grp.name == 'root'
		}
	}
}

fn test_lookup_group_id() {
	$if !windows {
		// Look up group 0 (wheel/root on most systems)
		grp := lookup_group_id(0) or {
			assert false, 'lookup_group_id(0) failed: ${err}'
			return
		}
		assert grp.gid == 0
		$if macos || darwin {
			assert grp.name == 'wheel'
		}
	}
}

fn test_lookup_group_not_found() {
	$if !windows {
		lookup_group('__nonexistent_group_12345__') or {
			assert err.msg().contains('not found')
			return
		}
		assert false, 'expected error for nonexistent group'
	}
}
