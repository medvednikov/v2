// vtest retry: 3
import db.sqlite

// Initial struct with fewer fields
struct UserV1 {
	id   int    @[primary; sql: serial]
	name string
}

// Extended struct with additional fields
@[table: 'UserV1']
struct UserV2 {
	id    int    @[primary; sql: serial]
	name  string
	email string
	age   int
}

// Struct with optional field
@[table: 'UserV1']
struct UserV3 {
	id       int     @[primary; sql: serial]
	name     string
	email    string
	age      int
	nickname ?string
}

// Struct with default value
@[table: 'UserV1']
struct UserV4 {
	id       int     @[primary; sql: serial]
	name     string
	email    string
	age      int
	nickname ?string
	score    int     @[default: '100']
}

fn test_create_adds_missing_columns() {
	db := sqlite.connect(':memory:')!

	// Create initial table with UserV1
	sql db {
		create table UserV1
	}!

	// Insert a row
	user1 := UserV1{
		name: 'Alice'
	}
	sql db {
		insert user1 into UserV1
	}!

	// Verify initial table structure
	initial_columns := get_columns(db, 'UserV1')
	assert 'id' in initial_columns
	assert 'name' in initial_columns
	assert 'email' !in initial_columns
	assert 'age' !in initial_columns

	// Now "upgrade" by creating with UserV2 - should add missing columns
	sql db {
		create table UserV2
	}!

	// Verify columns were added
	updated_columns := get_columns(db, 'UserV1')
	assert 'id' in updated_columns
	assert 'name' in updated_columns
	assert 'email' in updated_columns
	assert 'age' in updated_columns

	// Original data should still exist
	users := sql db {
		select from UserV2
	}!
	assert users.len == 1
	assert users[0].name == 'Alice'
	assert users[0].email == '' // default empty string
	assert users[0].age == 0 // default 0

	// Insert new data with new fields
	user2 := UserV2{
		name:  'Bob'
		email: 'bob@example.com'
		age:   30
	}
	sql db {
		insert user2 into UserV2
	}!

	all_users := sql db {
		select from UserV2
	}!
	assert all_users.len == 2
}

fn test_create_adds_nullable_column() {
	db := sqlite.connect(':memory:')!

	// Create with UserV2 first
	sql db {
		create table UserV2
	}!

	user := UserV2{
		name:  'Charlie'
		email: 'charlie@example.com'
		age:   25
	}
	sql db {
		insert user into UserV2
	}!

	// Upgrade to UserV3 which has optional nickname
	sql db {
		create table UserV3
	}!

	// Verify nickname column was added
	columns := get_columns(db, 'UserV1')
	assert 'nickname' in columns

	// Query using new struct
	users := sql db {
		select from UserV3
	}!
	assert users.len == 1
	assert users[0].nickname == none
}

fn test_create_adds_column_with_default() {
	db := sqlite.connect(':memory:')!

	// Create with UserV3 first
	sql db {
		create table UserV3
	}!

	user := UserV3{
		name:     'Dave'
		email:    'dave@example.com'
		age:      35
		nickname: 'D'
	}
	sql db {
		insert user into UserV3
	}!

	// Upgrade to UserV4 which has score with default
	sql db {
		create table UserV4
	}!

	// Verify score column was added
	columns := get_columns(db, 'UserV1')
	assert 'score' in columns

	// Existing row should have default value
	users := sql db {
		select from UserV4
	}!
	assert users.len == 1
	assert users[0].score == 100 // the default value
}

fn test_create_idempotent() {
	db := sqlite.connect(':memory:')!

	// Create same table multiple times - should not error
	sql db {
		create table UserV1
	}!

	sql db {
		create table UserV1
	}!

	sql db {
		create table UserV1
	}!

	// Table should still work
	user := UserV1{
		name: 'Eve'
	}
	sql db {
		insert user into UserV1
	}!

	users := sql db {
		select from UserV1
	}!
	assert users.len == 1
}

// Helper function to get column names from a table
fn get_columns(db sqlite.DB, table_name string) []string {
	result := db.exec('PRAGMA table_info(`${table_name}`);') or { return [] }
	mut columns := []string{}
	for row in result {
		if row.vals.len > 1 {
			columns << row.vals[1]
		}
	}
	return columns
}
