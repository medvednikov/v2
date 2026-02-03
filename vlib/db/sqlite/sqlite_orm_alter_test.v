// vtest retry: 3
import db.sqlite
import orm

// Test the ALTER TABLE ADD COLUMN functionality using direct ORM API

fn test_create_adds_missing_columns_via_orm_api() {
	mut db := sqlite.connect(':memory:')!
	defer {
		db.close() or {}
	}

	table := orm.Table{
		name: 'TestMigration'
	}

	// Create table with initial fields
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
				VAttribute{
					name:    'sql'
					has_arg: true
					kind:    .plain
					arg:     'serial'
				},
			]
		},
		orm.TableField{
			name: 'name'
			typ:  typeof[string]().idx
		},
	])!

	// Insert initial data
	db.insert(table, orm.QueryData{
		fields: ['name']
		data:   [orm.string_to_primitive('Alice')]
	})!

	// Verify initial structure
	initial_cols := get_column_names(db, 'TestMigration')
	assert 'id' in initial_cols
	assert 'name' in initial_cols
	assert initial_cols.len == 2

	// Now "migrate" by calling create with additional fields
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
				VAttribute{
					name:    'sql'
					has_arg: true
					kind:    .plain
					arg:     'serial'
				},
			]
		},
		orm.TableField{
			name: 'name'
			typ:  typeof[string]().idx
		},
		orm.TableField{
			name: 'email'
			typ:  typeof[string]().idx
		},
		orm.TableField{
			name: 'age'
			typ:  typeof[int]().idx
		},
	])!

	// Verify columns were added
	updated_cols := get_column_names(db, 'TestMigration')
	assert 'id' in updated_cols
	assert 'name' in updated_cols
	assert 'email' in updated_cols
	assert 'age' in updated_cols
	assert updated_cols.len == 4

	// Original data should still exist
	res := db.select(orm.SelectConfig{
		table:  table
		fields: ['id', 'name', 'email', 'age']
		types:  [typeof[int]().idx, typeof[string]().idx, typeof[string]().idx, typeof[int]().idx]
	}, orm.QueryData{}, orm.QueryData{})!

	assert res.len == 1
	assert res[0][1] as string == 'Alice'
	assert res[0][2] as string == '' // default empty string
	assert res[0][3] as int == 0 // default 0
}

fn test_create_adds_nullable_column_via_orm_api() {
	mut db := sqlite.connect(':memory:')!
	defer {
		db.close() or {}
	}

	table := orm.Table{
		name: 'TestNullable'
	}

	// Create table with initial field
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
		orm.TableField{
			name: 'name'
			typ:  typeof[string]().idx
		},
	])!

	// Insert data
	db.insert(table, orm.QueryData{
		fields: ['id', 'name']
		data:   [orm.int_to_primitive(1), orm.string_to_primitive('Bob')]
	})!

	// Add nullable column
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
		orm.TableField{
			name: 'name'
			typ:  typeof[string]().idx
		},
		orm.TableField{
			name:     'nickname'
			typ:      typeof[string]().idx
			nullable: true
		},
	])!

	// Verify column was added
	cols := get_column_names(db, 'TestNullable')
	assert 'nickname' in cols

	// Query to verify nullable column has NULL for existing row
	res := db.exec('SELECT nickname FROM TestNullable WHERE id = 1;')!
	assert res.len == 1
	assert res[0].vals[0] == '' // NULL appears as empty string in sqlite result
}

fn test_create_with_default_value_via_orm_api() {
	mut db := sqlite.connect(':memory:')!
	defer {
		db.close() or {}
	}

	table := orm.Table{
		name: 'TestDefault'
	}

	// Create table
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
		orm.TableField{
			name: 'name'
			typ:  typeof[string]().idx
		},
	])!

	// Insert data
	db.insert(table, orm.QueryData{
		fields: ['id', 'name']
		data:   [orm.int_to_primitive(1), orm.string_to_primitive('Charlie')]
	})!

	// Add column with explicit default
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
		orm.TableField{
			name: 'name'
			typ:  typeof[string]().idx
		},
		orm.TableField{
			name:        'score'
			typ:         typeof[int]().idx
			default_val: '100'
		},
	])!

	// Verify column was added with default value
	res := db.exec('SELECT score FROM TestDefault WHERE id = 1;')!
	assert res.len == 1
	assert res[0].vals[0] == '100'
}

fn test_create_idempotent_via_orm_api() {
	mut db := sqlite.connect(':memory:')!
	defer {
		db.close() or {}
	}

	table := orm.Table{
		name: 'TestIdempotent'
	}

	fields := [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
		orm.TableField{
			name: 'value'
			typ:  typeof[string]().idx
		},
	]

	// Call create multiple times - should not error
	db.create(table, fields)!
	db.create(table, fields)!
	db.create(table, fields)!

	// Table should work normally
	db.insert(table, orm.QueryData{
		fields: ['id', 'value']
		data:   [orm.int_to_primitive(1), orm.string_to_primitive('test')]
	})!

	res := db.select(orm.SelectConfig{
		table:  table
		fields: ['id', 'value']
		types:  [typeof[int]().idx, typeof[string]().idx]
	}, orm.QueryData{}, orm.QueryData{})!

	assert res.len == 1
}

fn test_create_skips_array_fields() {
	mut db := sqlite.connect(':memory:')!
	defer {
		db.close() or {}
	}

	table := orm.Table{
		name: 'TestArraySkip'
	}

	// Create with array field - should be skipped
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
		orm.TableField{
			name:   'items'
			typ:    typeof[int]().idx
			is_arr: true
		},
	])!

	// Only 'id' should exist
	cols := get_column_names(db, 'TestArraySkip')
	assert 'id' in cols
	assert 'items' !in cols
}

fn test_create_skips_fields_marked_skip() {
	mut db := sqlite.connect(':memory:')!
	defer {
		db.close() or {}
	}

	table := orm.Table{
		name: 'TestSkipAttr'
	}

	// First create table
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
	])!

	// Try to add a field with skip attribute
	db.create(table, [
		orm.TableField{
			name:  'id'
			typ:   typeof[int]().idx
			attrs: [
				VAttribute{
					name: 'primary'
				},
			]
		},
		orm.TableField{
			name: 'secret'
			typ:  typeof[string]().idx
			attrs: [
				VAttribute{
					name: 'skip'
				},
			]
		},
	])!

	// 'secret' should not be added
	cols := get_column_names(db, 'TestSkipAttr')
	assert 'id' in cols
	assert 'secret' !in cols
}

// Helper function
fn get_column_names(db sqlite.DB, table_name string) []string {
	result := db.exec('PRAGMA table_info(`${table_name}`);') or { return [] }
	mut columns := []string{}
	for row in result {
		if row.vals.len > 1 {
			columns << row.vals[1]
		}
	}
	return columns
}
