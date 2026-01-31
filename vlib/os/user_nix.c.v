module os

#include <pwd.h>
#include <grp.h>

// C structures for passwd and group entries
struct C.passwd {
	pw_name   &char // username
	pw_passwd &char // user password (usually 'x' or '*')
	pw_uid    u32   // user ID
	pw_gid    u32   // group ID
	pw_gecos  &char // real name / comment field
	pw_dir    &char // home directory
	pw_shell  &char // shell program
}

struct C.group {
	gr_name   &char  // group name
	gr_passwd &char  // group password
	gr_gid    u32    // group ID
	gr_mem    &&char // null-terminated array of pointers to member names
}

fn C.getpwnam(name &char) &C.passwd
fn C.getpwuid(uid u32) &C.passwd
fn C.getgrnam(name &char) &C.group
fn C.getgrgid(gid u32) &C.group

// User represents a user account on the system.
pub struct User {
pub:
	uid      u32    // user ID
	gid      u32    // primary group ID
	username string // login name
	name     string // user's real name or comment field
	home_dir string // home directory
	shell    string // shell program
}

// Group represents a group on the system.
pub struct Group {
pub:
	gid     u32      // group ID
	name    string   // group name
	members []string // list of group member usernames
}

// current_user returns the current user.
pub fn current_user() !User {
	return lookup_user_id(u32(getuid()))
}

// lookup_user looks up a user by username.
// If the user cannot be found, an error is returned.
pub fn lookup_user(username string) !User {
	pw := C.getpwnam(&char(username.str))
	if isnil(pw) {
		return error('user "${username}" not found')
	}
	return passwd_to_user(pw)
}

// lookup_user_id looks up a user by user ID.
// If the user cannot be found, an error is returned.
pub fn lookup_user_id(uid u32) !User {
	pw := C.getpwuid(uid)
	if isnil(pw) {
		return error('user with uid ${uid} not found')
	}
	return passwd_to_user(pw)
}

fn passwd_to_user(pw &C.passwd) User {
	return User{
		uid:      pw.pw_uid
		gid:      pw.pw_gid
		username: unsafe { cstring_to_vstring(pw.pw_name) }
		name:     unsafe { cstring_to_vstring(pw.pw_gecos) }
		home_dir: unsafe { cstring_to_vstring(pw.pw_dir) }
		shell:    unsafe { cstring_to_vstring(pw.pw_shell) }
	}
}

// lookup_group looks up a group by name.
// If the group cannot be found, an error is returned.
pub fn lookup_group(groupname string) !Group {
	gr := C.getgrnam(&char(groupname.str))
	if isnil(gr) {
		return error('group "${groupname}" not found')
	}
	return group_to_vgroup(gr)
}

// lookup_group_id looks up a group by group ID.
// If the group cannot be found, an error is returned.
pub fn lookup_group_id(gid u32) !Group {
	gr := C.getgrgid(gid)
	if isnil(gr) {
		return error('group with gid ${gid} not found')
	}
	return group_to_vgroup(gr)
}

fn group_to_vgroup(gr &C.group) Group {
	mut members := []string{}
	unsafe {
		mut i := 0
		for !isnil(gr.gr_mem[i]) {
			members << cstring_to_vstring(gr.gr_mem[i])
			i++
		}
	}
	return Group{
		gid:     gr.gr_gid
		name:    unsafe { cstring_to_vstring(gr.gr_name) }
		members: members
	}
}
