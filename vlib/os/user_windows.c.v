module os

// User represents a user account on the system.
pub struct User {
pub:
	uid      u32    // user ID (not applicable on Windows, always 0)
	gid      u32    // primary group ID (not applicable on Windows, always 0)
	username string // login name
	name     string // user's display name
	home_dir string // home directory
	shell    string // shell program (not applicable on Windows, empty)
}

// Group represents a group on the system.
pub struct Group {
pub:
	gid     u32      // group ID (not applicable on Windows, always 0)
	name    string   // group name
	members []string // list of group member usernames
}

// current_user returns the current user.
pub fn current_user() !User {
	username := loginname()!
	return User{
		uid:      0
		gid:      0
		username: username
		name:     username
		home_dir: home_dir()
		shell:    ''
	}
}

// lookup_user looks up a user by username.
// On Windows, this returns basic information only.
pub fn lookup_user(username string) !User {
	// TODO: implement using Windows API (NetUserGetInfo)
	return error('lookup_user is not fully implemented on Windows')
}

// lookup_user_id looks up a user by user ID.
// On Windows, user IDs are not used in the same way as Unix.
pub fn lookup_user_id(uid u32) !User {
	return error('lookup_user_id is not supported on Windows')
}

// lookup_group looks up a group by name.
// On Windows, this is not fully implemented.
pub fn lookup_group(groupname string) !Group {
	// TODO: implement using Windows API (NetLocalGroupGetInfo)
	return error('lookup_group is not fully implemented on Windows')
}

// lookup_group_id looks up a group by group ID.
// On Windows, group IDs are not used in the same way as Unix.
pub fn lookup_group_id(gid u32) !Group {
	return error('lookup_group_id is not supported on Windows')
}
