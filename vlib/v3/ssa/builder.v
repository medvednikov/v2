module ssa

import v3.flat
import v3.types

const arm64_force_external_syms = ['_malloc', '_free', '_calloc', '_realloc', '_exit', '_abort',
	'_memcpy', '_memmove', '_memset', '_memcmp', '___stdoutp', '___stderrp', '_puts', '_printf',
	'_write', '_read', '_open', '_close', '_fwrite', '_fflush', '_fopen', '_fclose', '_putchar',
	'_sprintf', '_snprintf', '_fprintf', '_sscanf', '_mmap', '_munmap', '_getcwd', '_access',
	'_readlink', '_getenv', '_strlen', '_opendir', '_readdir', '_closedir', '_mkdir', '_rmdir',
	'_unlink', '_rename', '_remove', '_stat', '_lstat', '_fstat', '_chmod', '_chdir', '_realpath',
	'_symlink', '_link', '_getpid', '_getuid', '_geteuid', '_fork', '_execve', '_execvp', '_waitpid',
	'_kill', '_system', '_posix_spawn', '_signal', '_atexit', '_fgets', '_fputs', '_fread', '_fseek',
	'_ftell', '_rewind', '_fileno', '_popen', '_pclose', '_dup', '_dup2', '_pipe', '_isatty',
	'_freopen', '_dprintf', '_getc', '_strdup', '_strcmp', '_strncmp', '_strchr', '_strrchr',
	'_strerror', '_strncasecmp', '_strcasecmp', '_atoi', '_atof', '_qsort', '_time', '_localtime_r',
	'_gmtime_r', '_mktime', '_gettimeofday', '_clock_gettime_nsec_np', '_mach_absolute_time',
	'_mach_timebase_info', '_nanosleep', '_sleep', '_usleep', '_strftime', '_task_info',
	'_mach_task_self_', '_rand', '_srand', '_isdigit', '_isspace', '_tolower', '_toupper', '_setenv',
	'_unsetenv', '_sysconf', '_uname', '_gethostname', '_pthread_mutex_init', '_pthread_mutex_lock',
	'_pthread_mutex_unlock', '_pthread_mutex_destroy', '_pthread_self', '_pthread_create',
	'_pthread_join', '_pthread_attr_init', '_pthread_attr_setstacksize', '_pthread_attr_destroy',
	'_arc4random_buf', '_proc_pidpath', '_backtrace', '_backtrace_symbols', '_backtrace_symbols_fd',
	'_dispatch_semaphore_create', '_dispatch_semaphore_signal', '_dispatch_semaphore_wait',
	'_dispatch_time', '_dispatch_release', '_setvbuf', '_setbuf', '_memchr', '_getlogin_r',
	'_getppid', '_getgid', '_getegid', '_ftruncate', '_mkstemp', '_statvfs', '_chown', '_sigaction',
	'_sigemptyset', '_sigaddset', '_sigprocmask', '_select', '_kqueue', '_abs', '_tcgetattr',
	'_tcsetattr', '_ioctl', '_getchar', '_getline', '_fdopen', '_feof', '_ferror', '_setpgid',
	'_ptrace', '_wait', '_timegm', '_clock_gettime', '_aligned_alloc', '_utime', '_getlogin',
	'_environ', '___error', '___stdinp', '__dyld_get_image_name', '__dyld_get_image_header', '_cos',
	'_sin', '_tan', '_acos', '_asin', '_atan', '_atan2', '_cosh', '_sinh', '_tanh', '_acosh',
	'_asinh', '_atanh', '_exp', '_exp2', '_log', '_log2', '_log10', '_pow', '_sqrt', '_cbrt', '_ceil',
	'_floor', '_round', '_trunc', '_fmod', '_remainder', '_fabs', '_copysign', '_fmax', '_fmin',
	'_hypot', '_ldexp', '_frexp', '_modf', '_scalbn', '_ilogb', '_logb', '_erf', '_erfc', '_lgamma',
	'_tgamma', '_j0', '_j1', '_jn', '_y0', '_y1', '_yn', '_mprotect', '_sys_icache_invalidate',
	'_objc_msgSend', '_objc_getClass', '_sel_registerName', '_objc_alloc_init',
	'_objc_autoreleasePoolPush', '_objc_autoreleasePoolPop', '_MTLCreateSystemDefaultDevice',
	'_dlopen', '_dlsym']

pub struct Builder {
mut:
	m                  &Module            = unsafe { nil }
	a                  &flat.FlatAst      = unsafe { nil }
	tc                 &types.TypeChecker = unsafe { nil }
	used_fns           map[string]bool
	cur_module         string
	cur_func           int
	cur_block          BlockID
	vars               map[string]ValueID
	var_type_names     map[string]string
	i64_type           TypeID
	i32_type           TypeID
	i8_type            TypeID
	i1_type            TypeID
	void_type          TypeID
	str_type           TypeID
	array_type         TypeID
	map_type           TypeID
	map_state_type     TypeID
	fn_types           map[string]TypeID
	fn_ids             map[string]int
	const_exprs        map[string]flat.NodeId
	struct_types       map[string]TypeID
	struct_field_types map[string]string
	break_targets      []BlockID
	continue_targets   []BlockID
	top_level_main     bool
}

pub fn build(a_ &flat.FlatAst) &Module {
	return build_with_used(a_, map[string]bool{}, unsafe { nil })
}

pub fn build_with_used(a_ &flat.FlatAst, used_fns map[string]bool, tc &types.TypeChecker) &Module {
	mut b := Builder{
		m:        Module.new()
		a:        unsafe { a_ }
		tc:       unsafe { tc }
		used_fns: used_fns
	}
	b.void_type = TypeID(0)
	b.i64_type = b.m.type_store.get_int(64)
	b.i32_type = b.m.type_store.get_int(32)
	b.i8_type = b.m.type_store.get_int(8)
	b.i1_type = b.m.type_store.get_int(1)
	mut str_fields := []TypeID{}
	str_fields << b.m.type_store.get_ptr(b.i8_type)
	str_fields << b.i32_type
	mut str_field_names := []string{}
	str_field_names << 'str'
	str_field_names << 'len'
	b.str_type = b.m.type_store.register(Type{
		kind:        .struct_t
		fields:      str_fields
		field_names: str_field_names
	})
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut array_fields := []TypeID{}
	array_fields << ptr_i8
	array_fields << b.i32_type
	array_fields << b.i32_type
	array_fields << b.i32_type
	array_fields << b.i32_type
	array_fields << b.i32_type
	mut array_field_names := []string{}
	array_field_names << 'data'
	array_field_names << 'offset'
	array_field_names << 'len'
	array_field_names << 'cap'
	array_field_names << 'flags'
	array_field_names << 'element_size'
	b.array_type = b.m.type_store.register(Type{
		kind:        .struct_t
		fields:      array_fields
		field_names: array_field_names
	})
	mut map_state_fields := []TypeID{}
	map_state_fields << ptr_i8
	map_state_fields << ptr_i8
	map_state_fields << b.i64_type
	map_state_fields << b.i64_type
	map_state_fields << b.i64_type
	map_state_fields << b.i64_type
	mut map_state_field_names := []string{}
	map_state_field_names << 'keys'
	map_state_field_names << 'vals'
	map_state_field_names << 'cap'
	map_state_field_names << 'len'
	map_state_field_names << 'key_size'
	map_state_field_names << 'val_size'
	b.map_state_type = b.m.type_store.register(Type{
		kind:        .struct_t
		fields:      map_state_fields
		field_names: map_state_field_names
	})
	mut map_fields := []TypeID{}
	map_fields << b.m.type_store.get_ptr(b.map_state_type)
	mut map_field_names := []string{}
	map_field_names << 'state'
	b.map_type = b.m.type_store.register(Type{
		kind:        .struct_t
		fields:      map_fields
		field_names: map_field_names
	})
	b.register_types()
	b.register_consts()
	b.register_globals()
	b.register_functions()
	b.build_functions()
	return b.m
}

fn (mut b Builder) register_types() {
	mut cur_module := ''
	for node in b.a.nodes {
		if node.kind == .module_decl {
			cur_module = node.value
			continue
		}
		if node.kind == .struct_decl {
			typ_id := b.m.type_store.register(Type{
				kind: .struct_t
			})
			b.register_struct_type_name(node.value, cur_module, typ_id)
		}
	}

	cur_module = ''
	for node in b.a.nodes {
		if node.kind == .module_decl {
			cur_module = node.value
			continue
		}
		if node.kind == .struct_decl {
			mut field_types := []TypeID{}
			mut field_names := []string{}
			for i in 0 .. node.children_count {
				f := b.a.child_node(&node, i)
				field_types << b.resolve_type_in_module(f.typ, cur_module)
				field_names << f.value
				b.struct_field_types[node.value + '.' + f.value] = f.typ
				short_name := node.value.all_after('.')
				b.struct_field_types[short_name + '.' + f.value] = f.typ
				if cur_module.len > 0 && cur_module != 'main' && cur_module != 'builtin' {
					b.struct_field_types[cur_module + '.' + short_name + '.' + f.value] = f.typ
				}
			}
			typ_id := b.struct_type_id_for_decl(node.value, cur_module)
			b.m.type_store.types[typ_id] = Type{
				kind:        .struct_t
				fields:      field_types
				field_names: field_names
			}
		}
	}
}

fn (mut b Builder) register_struct_type_name(name string, module_name string, typ_id TypeID) {
	b.struct_types[name] = typ_id
	short_name := name.all_after('.')
	if short_name !in b.struct_types {
		b.struct_types[short_name] = typ_id
	}
	if module_name.len > 0 && module_name != 'main' && module_name != 'builtin' {
		qualified_name := module_name + '.' + short_name
		b.struct_types[qualified_name] = typ_id
	}
}

fn (b &Builder) struct_type_id_for_decl(name string, module_name string) TypeID {
	short_name := name.all_after('.')
	if module_name.len > 0 && module_name != 'main' && module_name != 'builtin' {
		qualified_name := module_name + '.' + short_name
		if typ := b.struct_types[qualified_name] {
			return typ
		}
	}
	if typ := b.struct_types[name] {
		return typ
	}
	if typ := b.struct_types[short_name] {
		return typ
	}
	return TypeID(0)
}

fn (mut b Builder) register_consts() {
	mut cur_module := ''
	for node in b.a.nodes {
		if node.kind == .module_decl {
			cur_module = node.value
			continue
		}
		if node.kind == .const_decl {
			for i in 0 .. node.children_count {
				field_id := b.a.child(&node, i)
				if int(field_id) < 0 {
					continue
				}
				field := b.a.nodes[int(field_id)]
				if field.kind != .const_field || field.children_count == 0 {
					continue
				}
				expr_id := b.a.child(&field, 0)
				if cur_module.len > 0 && cur_module != 'main' {
					b.const_exprs['${cur_module}.${field.value}'] = expr_id
				} else {
					b.const_exprs[field.value] = expr_id
				}
			}
		}
	}
}

fn (mut b Builder) register_globals() {
	for node in b.a.nodes {
		if node.kind == .global_decl {
			for i in 0 .. node.children_count {
				f := b.a.child_node(&node, i)
				typ := b.resolve_type(f.typ)
				b.vars[f.value] = b.m.add_global(f.value, typ)
			}
		}
	}
	b.ensure_runtime_global('g_main_argc', b.i64_type)
	b.ensure_runtime_global('g_main_argv',
		b.m.type_store.get_ptr(b.m.type_store.get_ptr(b.i8_type)))
}

fn (mut b Builder) ensure_runtime_global(name string, typ TypeID) {
	if name in b.vars {
		return
	}
	for v in b.m.values {
		if v.kind == .global && v.name == name {
			b.vars[name] = v.id
			return
		}
	}
	b.vars[name] = b.m.add_global(name, typ)
}

fn (mut b Builder) register_functions() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut p1 := []TypeID{}
	mut p2 := []TypeID{}
	mut p3 := []TypeID{}
	// C library externs
	p3 = []TypeID{}
	p3 << b.i64_type
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('write', b.i64_type, p3)
	b.register_extern('read', b.i64_type, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << b.i64_type
	p3 << b.i64_type
	b.register_extern('open', b.i64_type, p3)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('putchar', b.i64_type, p1)
	b.register_extern('getchar', b.i64_type, []TypeID{})
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('close', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('puts', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('strlen', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('strerror', ptr_i8, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('feof', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('ferror', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('fclose', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('pclose', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('ftell', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('rewind', b.void_type, p1)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('fputs', b.i64_type, p2)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('fopen', ptr_i8, p2)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('popen', ptr_i8, p2)
	mut p4 := []TypeID{}
	p4 << ptr_i8
	p4 << b.i64_type
	p4 << b.i64_type
	p4 << ptr_i8
	b.register_extern('fread', b.i64_type, p4)
	p4 = []TypeID{}
	p4 << ptr_i8
	p4 << b.i64_type
	p4 << b.i64_type
	p4 << ptr_i8
	b.register_extern('fwrite', b.i64_type, p4)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << b.i64_type
	p3 << b.i64_type
	b.register_extern('fseek', b.i64_type, p3)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('malloc', ptr_i8, p1)
	p2 = []TypeID{}
	p2 << b.i64_type
	p2 << b.i64_type
	b.register_extern('calloc', ptr_i8, p2)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << b.i64_type
	b.register_extern('realloc', ptr_i8, p2)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('memcpy', ptr_i8, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('memmove', ptr_i8, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << b.i64_type
	p3 << b.i64_type
	b.register_extern('memset', ptr_i8, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('memcmp', b.i64_type, p3)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('exit', b.void_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('fflush', b.void_type, p1)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << b.i64_type
	b.register_extern('access', b.i64_type, p2)
	b.register_extern('mkdir', b.i64_type, p2)
	b.register_extern('getcwd', ptr_i8, p2)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('remove', b.i64_type, p1)
	b.register_extern('unlink', b.i64_type, p1)
	b.register_extern('rmdir', b.i64_type, p1)
	b.register_extern('chdir', b.i64_type, p1)
	b.register_extern('getenv', ptr_i8, p1)
	b.register_extern('system', b.i64_type, p1)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('readlink', b.i64_type, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('setenv', b.i64_type, p3)
	p3 = []TypeID{}
	p3 << b.i64_type
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('waitpid', b.i64_type, p3)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('realpath', ptr_i8, p2)
	b.register_extern('pthread_mutex_init', b.i64_type, p2)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('pthread_mutex_lock', b.i64_type, p1)
	b.register_extern('pthread_mutex_trylock', b.i64_type, p1)
	b.register_extern('pthread_mutex_unlock', b.i64_type, p1)
	b.register_extern('pthread_mutex_destroy', b.i64_type, p1)
	b.register_extern('pthread_self', b.i64_type, []TypeID{})
	b.register_extern('getpid', b.i64_type, []TypeID{})
	b.register_extern('mach_absolute_time', b.i64_type, []TypeID{})
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('mach_timebase_info', b.void_type, p1)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('clock_gettime_nsec_np', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('time', b.i64_type, p1)
	b.register_extern('mktime', b.i64_type, p1)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('localtime_r', ptr_i8, p2)
	b.register_extern('gmtime_r', ptr_i8, p2)
	p4 = []TypeID{}
	p4 << ptr_i8
	p4 << b.i64_type
	p4 << ptr_i8
	p4 << ptr_i8
	b.register_extern('strftime', b.i64_type, p4)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('gettimeofday', b.i64_type, p2)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('sleep', b.i64_type, p1)
	b.register_extern('usleep', b.i64_type, p1)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('nanosleep', b.i64_type, p2)
	p2 = []TypeID{}
	p2 << b.i64_type
	p2 << ptr_i8
	b.register_extern('clock_gettime', b.i64_type, p2)
	b.register_basic_format_stubs()
	b.register_string_plus_stubs()
	b.register_bench_runtime_stubs()
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('free', b.void_type, p1)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('fprintf', b.void_type, p2)

	mut cur_module := ''
	for node in b.a.nodes {
		if node.kind == .module_decl {
			cur_module = node.value
			continue
		}
		if node.kind == .fn_decl {
			if b.skip_source_fn_in_module(node.value, cur_module) {
				continue
			}
			if b.used_fns.len > 0 && !b.fn_is_used(node.value) {
				continue
			}
			ret_type := b.resolve_type_in_module(node.typ, cur_module)
			mut param_types := []TypeID{}
			for i in 0 .. node.children_count {
				child := b.a.child_node(&node, i)
				if child.kind == .param {
					param_types << b.resolve_type_in_module(child.typ, cur_module)
				}
			}
			fn_type := b.m.type_store.register(Type{
				kind:     .func_t
				ret_type: ret_type
				params:   param_types
			})
			b.fn_types[node.value] = fn_type
			func_id := b.m.new_function(node.value, ret_type)
			b.fn_ids[node.value] = func_id
		}
	}
	b.register_top_level_main()
	b.register_wyhash_stubs()
	b.register_string_eq_stub()
	b.register_fast_string_eq_stub()
	b.register_string_lt_stub()
	b.register_string_trim_stubs()
	b.register_ierror_stubs()
	b.register_array_runtime_stubs()
	b.register_arguments_stub()
	b.register_panic_stub()
	b.register_string_builder_stubs()
	b.register_path_runtime_stubs()
	b.register_map_runtime_stubs()
	b.register_u8_runtime_stubs()
	b.register_heap_tracking_stubs()
	b.register_process_capture_stubs()
	b.register_array_string_stubs()
	b.register_fixed_array_contains_stubs()
	b.register_array_contains_stubs()
}

fn (mut b Builder) register_extern(name string, ret TypeID, params []TypeID) {
	fn_type := b.m.type_store.register(Type{
		kind:     .func_t
		ret_type: ret
		params:   params
	})
	b.fn_types[name] = fn_type
	func_id := b.m.new_function(name, ret)
	b.fn_ids[name] = func_id
	mut f := b.m.funcs[func_id]
	f.is_c_extern = true
	b.m.funcs[func_id] = f
}

fn (mut b Builder) register_runtime_extern(name string, ret TypeID, params []TypeID) {
	if b.has_fn_decl(name) {
		return
	}
	b.register_extern(name, ret, params)
}

fn (b &Builder) has_fn_decl(name string) bool {
	for node in b.a.nodes {
		if node.kind == .fn_decl && node.value == name {
			return true
		}
	}
	return false
}

fn (b &Builder) skip_source_fn(name string) bool {
	if name in ['_wymix', 'wyhash', 'wyhash64', 'string__eq', 'string__lt', 'array_new', 'array_get',
		'string__plus', 'string_plus_many', 'string.trim_right', 'array_push', 'array.push_many',
		'array_clone', 'panic', 'fast_string_eq', 'strings.new_builder',
		'strings.Builder.write_string', 'strings.Builder.writeln', 'strings.Builder.str',
		'strings.Builder.write_ptr', 'strings.Builder.write_u8', 'strings.Builder.write_runes',
		'strings.Builder.free', 'strings.Builder.last_n', 'Builder.write_string', 'Builder.writeln',
		'Builder.str', 'Builder.write_ptr', 'Builder.write_u8', 'Builder.write_runes', 'Builder.free',
		'Builder.last_n', 'new_map', 'map__set', 'map__get', 'map__exists', 'map__get_check',
		'map__get_or_set', 'map__delete', 'map__clear', 'map__clone', 'v3_map_find',
		'v3_map_set_sized', 'u8.is_digit', 'u8.is_letter', 'u8.is_alnum', 'u8.is_capital', 'bytestr',
		'[]u8.bytestr', '_ht_alloc', '_ht_free', 'f32_to_str_l', 'f32_to_str_l_with_dot',
		'f64_to_str_l', 'f64_to_str_l_with_dot', 'current_rss_kb', 'macos_rss_kb', 'linux_rss_kb',
		'arguments', 'tos2', 'tos3', 'tos_clone', 'normalize_path_in_builder', 'fxx_to_str_l_parse',
		'fxx_to_str_l_parse_with_dot'] {
		return true
	}
	return name.starts_with('print_backtrace') || name.starts_with('backtrace_')
		|| name.starts_with('map.')
		|| name in ['print_libbacktrace', 'eprint_libbacktrace', 'bsd_backtrace_resolve_atos']
}

fn (b &Builder) skip_source_fn_in_module(name string, module_name string) bool {
	if module_name == 'c' && name.starts_with('Gen.') {
		return true
	}
	return b.skip_source_fn(name)
}

fn (mut b Builder) register_top_level_main() {
	if 'main' in b.fn_ids || !b.has_top_level_stmts() {
		return
	}
	fn_type := b.m.type_store.register(Type{
		kind:     .func_t
		ret_type: b.void_type
	})
	b.fn_types['main'] = fn_type
	b.fn_ids['main'] = b.m.new_function('main', b.void_type)
	b.top_level_main = true
}

fn (b &Builder) has_top_level_stmts() bool {
	return b.top_level_stmt_ids().len > 0
}

fn (b &Builder) top_level_stmt_ids() []flat.NodeId {
	mut ids := []flat.NodeId{}
	for file_idx, file_node in b.a.nodes {
		if file_idx < b.a.user_code_start || file_node.kind != .file
			|| file_node.children_count == 0 {
			continue
		}
		for i in 0 .. file_node.children_count {
			child_id := b.a.child(&file_node, i)
			if int(child_id) < b.a.user_code_start {
				continue
			}
			child := b.a.nodes[int(child_id)]
			if b.is_top_level_stmt(child) {
				ids << child_id
			}
		}
	}
	return ids
}

fn (b &Builder) is_top_level_stmt(node flat.Node) bool {
	return match node.kind {
		.expr_stmt, .assign, .decl_assign, .selector_assign, .index_assign, .for_stmt,
		.for_in_stmt, .if_expr, .assert_stmt, .block {
			true
		}
		else {
			false
		}
	}
}

fn (mut b Builder) register_wyhash_stubs() {
	mut p2 := []TypeID{}
	p2 << b.i64_type
	p2 << b.i64_type
	wymix_id := b.register_synthetic_function('_wymix', b.i64_type, p2)
	b.generate_wymix_body(wymix_id)
	wyhash64_id := b.register_synthetic_function('wyhash64', b.i64_type, p2)
	b.generate_wyhash64_body(wyhash64_id)

	ptr_u8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_u64 := b.m.type_store.get_ptr(b.i64_type)
	mut p4 := []TypeID{}
	p4 << ptr_u8
	p4 << b.i64_type
	p4 << b.i64_type
	p4 << ptr_u64
	wyhash_id := b.register_synthetic_function('wyhash', b.i64_type, p4)
	b.generate_wyhash_body(wyhash_id)
}

fn (mut b Builder) register_synthetic_function(name string, ret TypeID, params []TypeID) int {
	fn_type := b.m.type_store.register(Type{
		kind:     .func_t
		ret_type: ret
		params:   params
	})
	b.fn_types[name] = fn_type
	func_id := b.m.new_function(name, ret)
	b.fn_ids[name] = func_id
	mut f := b.m.funcs[func_id]
	f.typ = ret
	f.blocks = []BlockID{}
	f.params = []ValueID{}
	f.is_c_extern = false
	b.m.funcs[func_id] = f
	return func_id
}

fn (mut b Builder) func_add_argument(func_id int, typ TypeID, name string) ValueID {
	mut f := b.m.funcs[func_id]
	param := b.m.add_value(.argument, typ, name, f.params.len)
	f.params << param
	b.m.funcs[func_id] = f
	return param
}

fn (mut b Builder) block_instr0(op OpCode, block_id BlockID, typ TypeID) ValueID {
	ops := []ValueID{}
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr1(op OpCode, block_id BlockID, typ TypeID, a ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr2(op OpCode, block_id BlockID, typ TypeID, a ValueID, c ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr3(op OpCode, block_id BlockID, typ TypeID, a ValueID, c ValueID, d ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	ops << d
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr4(op OpCode, block_id BlockID, typ TypeID, a ValueID, c ValueID, d ValueID, e ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	ops << d
	ops << e
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_struct_field_ptr(block_id BlockID, base_addr ValueID, typ_id TypeID, field_idx int) ValueID {
	typ := b.m.type_store.types[typ_id]
	field_type := if field_idx < typ.fields.len { typ.fields[field_idx] } else { b.i64_type }
	offset := b.m.struct_field_offset(typ_id, field_idx)
	off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
	return b.block_instr2(.get_element_ptr, block_id, b.m.type_store.get_ptr(field_type),
		base_addr, off_const)
}

fn (mut b Builder) block_load_array_int_field(block_id BlockID, arr_ptr ValueID, field_idx int) ValueID {
	field_ptr := b.block_struct_field_ptr(block_id, arr_ptr, b.array_type, field_idx)
	field32 := b.block_instr1(.load, block_id, b.i32_type, field_ptr)
	return b.block_instr1(.zext, block_id, b.i64_type, field32)
}

fn (mut b Builder) register_basic_format_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut p1_ptr := []TypeID{}
	p1_ptr << ptr_i8
	tos2_id := b.register_synthetic_function('tos2', b.str_type, p1_ptr)
	b.generate_tos2_body(tos2_id)
	tos3_id := b.register_synthetic_function('tos3', b.str_type, p1_ptr)
	b.generate_tos2_body(tos3_id)
	tos_clone_id := b.register_synthetic_function('tos_clone', b.str_type, p1_ptr)
	b.generate_tos_clone_body(tos_clone_id)

	mut p1_i64 := []TypeID{}
	p1_i64 << b.i64_type
	int_str_id := b.register_synthetic_function('int_str', b.str_type, p1_i64)
	b.generate_const_string_body(int_str_id, '0')

	mut p1_i1 := []TypeID{}
	p1_i1 << b.i1_type
	bool_str_id := b.register_synthetic_function('bool_str', b.str_type, p1_i1)
	b.generate_const_string_body(bool_str_id, 'false')

	mut p2_i64 := []TypeID{}
	p2_i64 << b.i64_type
	p2_i64 << b.i64_type
	format_int_id := b.register_synthetic_function('strconv__format_int', b.str_type, p2_i64)
	b.generate_const_string_body(format_int_id, '0')
	format_uint_id := b.register_synthetic_function('strconv__format_uint', b.str_type, p2_i64)
	b.generate_const_string_body(format_uint_id, '0')

	f32_id := b.register_synthetic_function('strconv__f32_to_str_l', b.str_type, p1_i64)
	b.generate_const_string_body(f32_id, '0.0')
	f64_id := b.register_synthetic_function('strconv__f64_to_str_l', b.str_type, p1_i64)
	b.generate_const_string_body(f64_id, '0.0')
}

fn (mut b Builder) generate_const_string_body(func_id int, value string) {
	entry := b.m.add_block(func_id, 'entry')
	result := b.m.add_value(.string_literal, b.str_type, value, 0)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_bench_runtime_stubs() {
	for name in ['current_rss_kb', 'macos_rss_kb', 'linux_rss_kb'] {
		id := b.register_synthetic_function(name, b.i64_type, []TypeID{})
		b.generate_const_i64_body(id, '0')
	}
}

fn (mut b Builder) generate_tos2_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	entry := b.m.add_block(func_id, 'entry')
	s := b.func_add_argument(func_id, ptr_i8, 's')
	strlen_ref := b.m.add_value(.func_ref, b.i64_type, 'strlen', b.fn_ids['strlen'])
	len := b.block_instr2(.call, entry, b.i64_type, strlen_ref, s)
	result := b.emit_make_string(entry, s, len)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_tos_clone_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	entry := b.m.add_block(func_id, 'entry')
	s := b.func_add_argument(func_id, ptr_i8, 's')
	strlen_ref := b.m.add_value(.func_ref, b.i64_type, 'strlen', b.fn_ids['strlen'])
	len := b.block_instr2(.call, entry, b.i64_type, strlen_ref, s)
	one := b.m.get_or_add_const(b.i64_type, '1')
	alloc_len := b.block_instr2(.add, entry, b.i64_type, len, one)
	malloc_ref := b.m.add_value(.func_ref, b.void_type, 'malloc', b.fn_ids['malloc'])
	out_data := b.block_instr2(.call, entry, ptr_i8, malloc_ref, alloc_len)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, entry, ptr_i8, memcpy_ref, out_data, s, len)
	zero8 := b.m.get_or_add_const(b.i8_type, '0')
	term_ptr := b.block_instr2(.add, entry, ptr_i8, out_data, len)
	b.block_instr2(.store, entry, b.void_type, zero8, term_ptr)
	result := b.emit_make_string(entry, out_data, len)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_string_plus_stubs() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	plus_id := b.register_synthetic_function('string__plus', b.str_type, p2)
	b.generate_string_plus_body(plus_id)

	mut p_many := []TypeID{}
	p_many << b.i64_type
	p_many << b.m.type_store.get_ptr(b.str_type)
	many_id := b.register_synthetic_function('string_plus_many', b.str_type, p_many)
	b.generate_string_plus_many_body(many_id)
}

fn (mut b Builder) emit_make_string(block_id BlockID, data ValueID, len64 ValueID) ValueID {
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	alloca_out := b.block_instr0(.alloca, block_id, ptr_string)
	data_ptr := b.block_struct_field_ptr(block_id, alloca_out, b.str_type, 0)
	len_ptr := b.block_struct_field_ptr(block_id, alloca_out, b.str_type, 1)
	b.block_instr2(.store, block_id, b.void_type, data, data_ptr)
	b.block_instr2(.store, block_id, b.void_type, len64, len_ptr)
	return b.block_instr1(.load, block_id, b.str_type, alloca_out)
}

fn (mut b Builder) generate_string_plus_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	left := b.func_add_argument(func_id, b.str_type, 'left')
	right := b.func_add_argument(func_id, b.str_type, 'right')

	alloca_left := b.block_instr0(.alloca, entry, ptr_string)
	alloca_right := b.block_instr0(.alloca, entry, ptr_string)
	b.block_instr2(.store, entry, b.void_type, left, alloca_left)
	b.block_instr2(.store, entry, b.void_type, right, alloca_right)

	left_data_ptr := b.block_struct_field_ptr(entry, alloca_left, b.str_type, 0)
	left_len_ptr := b.block_struct_field_ptr(entry, alloca_left, b.str_type, 1)
	right_data_ptr := b.block_struct_field_ptr(entry, alloca_right, b.str_type, 0)
	right_len_ptr := b.block_struct_field_ptr(entry, alloca_right, b.str_type, 1)
	left_data := b.block_instr1(.load, entry, ptr_i8, left_data_ptr)
	right_data := b.block_instr1(.load, entry, ptr_i8, right_data_ptr)
	left_len32 := b.block_instr1(.load, entry, b.i32_type, left_len_ptr)
	right_len32 := b.block_instr1(.load, entry, b.i32_type, right_len_ptr)
	left_len := b.block_instr1(.zext, entry, b.i64_type, left_len32)
	right_len := b.block_instr1(.zext, entry, b.i64_type, right_len32)
	total_len := b.block_instr2(.add, entry, b.i64_type, left_len, right_len)
	one := b.m.get_or_add_const(b.i64_type, '1')
	alloc_len := b.block_instr2(.add, entry, b.i64_type, total_len, one)

	malloc_ref := b.m.add_value(.func_ref, b.void_type, 'malloc', b.fn_ids['malloc'])
	out_data := b.block_instr2(.call, entry, ptr_i8, malloc_ref, alloc_len)
	memcpy_ref_left := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, entry, ptr_i8, memcpy_ref_left, out_data, left_data, left_len)
	right_dest := b.block_instr2(.add, entry, ptr_i8, out_data, left_len)
	memcpy_ref_right := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, entry, ptr_i8, memcpy_ref_right, right_dest, right_data, right_len)
	zero8 := b.m.get_or_add_const(b.i8_type, '0')
	term_ptr := b.block_instr2(.add, entry, ptr_i8, out_data, total_len)
	b.block_instr2(.store, entry, b.void_type, zero8, term_ptr)

	result := b.emit_make_string(entry, out_data, total_len)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_string_plus_many_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	count := b.func_add_argument(func_id, b.i64_type, 'count')
	input_base := b.func_add_argument(func_id, ptr_string, 'input_base')

	alloca_i := b.block_instr0(.alloca, entry, ptr_i64)
	alloca_total := b.block_instr0(.alloca, entry, ptr_i64)
	alloca_written := b.block_instr0(.alloca, entry, ptr_i64)
	zero64 := b.m.get_or_add_const(b.i64_type, '0')
	one64 := b.m.get_or_add_const(b.i64_type, '1')
	stride := b.m.get_or_add_const(b.i64_type, '${b.m.type_size(b.str_type)}')
	b.block_instr2(.store, entry, b.void_type, zero64, alloca_i)
	b.block_instr2(.store, entry, b.void_type, zero64, alloca_total)

	sum_check := b.m.add_block(func_id, 'string_plus_many_sum_check')
	sum_body := b.m.add_block(func_id, 'string_plus_many_sum_body')
	alloc_block := b.m.add_block(func_id, 'string_plus_many_alloc')
	b.block_instr1(.jmp, entry, b.void_type, ValueID(sum_check))

	i_sum := b.block_instr1(.load, sum_check, b.i64_type, alloca_i)
	more_sum := b.block_instr2(.lt, sum_check, b.i1_type, i_sum, count)
	b.block_instr3(.br, sum_check, b.void_type, more_sum, ValueID(sum_body), ValueID(alloc_block))

	sum_item_off := b.block_instr2(.mul, sum_body, b.i64_type, i_sum, stride)
	sum_item_ptr := b.block_instr2(.get_element_ptr, sum_body, ptr_string, input_base, sum_item_off)
	sum_len_ptr := b.block_struct_field_ptr(sum_body, sum_item_ptr, b.str_type, 1)
	sum_len32 := b.block_instr1(.load, sum_body, b.i32_type, sum_len_ptr)
	sum_len := b.block_instr1(.zext, sum_body, b.i64_type, sum_len32)
	old_total := b.block_instr1(.load, sum_body, b.i64_type, alloca_total)
	new_total := b.block_instr2(.add, sum_body, b.i64_type, old_total, sum_len)
	next_i_sum := b.block_instr2(.add, sum_body, b.i64_type, i_sum, one64)
	b.block_instr2(.store, sum_body, b.void_type, new_total, alloca_total)
	b.block_instr2(.store, sum_body, b.void_type, next_i_sum, alloca_i)
	b.block_instr1(.jmp, sum_body, b.void_type, ValueID(sum_check))

	total_len := b.block_instr1(.load, alloc_block, b.i64_type, alloca_total)
	alloc_len := b.block_instr2(.add, alloc_block, b.i64_type, total_len, one64)
	malloc_ref := b.m.add_value(.func_ref, b.void_type, 'malloc', b.fn_ids['malloc'])
	out_data := b.block_instr2(.call, alloc_block, ptr_i8, malloc_ref, alloc_len)
	b.block_instr2(.store, alloc_block, b.void_type, zero64, alloca_i)
	b.block_instr2(.store, alloc_block, b.void_type, zero64, alloca_written)

	copy_check := b.m.add_block(func_id, 'string_plus_many_copy_check')
	copy_body := b.m.add_block(func_id, 'string_plus_many_copy_body')
	done := b.m.add_block(func_id, 'string_plus_many_done')
	b.block_instr1(.jmp, alloc_block, b.void_type, ValueID(copy_check))

	i_copy := b.block_instr1(.load, copy_check, b.i64_type, alloca_i)
	more_copy := b.block_instr2(.lt, copy_check, b.i1_type, i_copy, count)
	b.block_instr3(.br, copy_check, b.void_type, more_copy, ValueID(copy_body), ValueID(done))

	copy_item_off := b.block_instr2(.mul, copy_body, b.i64_type, i_copy, stride)
	copy_item_ptr := b.block_instr2(.get_element_ptr, copy_body, ptr_string, input_base,
		copy_item_off)
	copy_data_ptr := b.block_struct_field_ptr(copy_body, copy_item_ptr, b.str_type, 0)
	copy_len_ptr := b.block_struct_field_ptr(copy_body, copy_item_ptr, b.str_type, 1)
	copy_data := b.block_instr1(.load, copy_body, ptr_i8, copy_data_ptr)
	copy_len32 := b.block_instr1(.load, copy_body, b.i32_type, copy_len_ptr)
	copy_len := b.block_instr1(.zext, copy_body, b.i64_type, copy_len32)
	written := b.block_instr1(.load, copy_body, b.i64_type, alloca_written)
	dest := b.block_instr2(.add, copy_body, ptr_i8, out_data, written)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, copy_body, ptr_i8, memcpy_ref, dest, copy_data, copy_len)
	new_written := b.block_instr2(.add, copy_body, b.i64_type, written, copy_len)
	next_i_copy := b.block_instr2(.add, copy_body, b.i64_type, i_copy, one64)
	b.block_instr2(.store, copy_body, b.void_type, new_written, alloca_written)
	b.block_instr2(.store, copy_body, b.void_type, next_i_copy, alloca_i)
	b.block_instr1(.jmp, copy_body, b.void_type, ValueID(copy_check))

	zero8 := b.m.get_or_add_const(b.i8_type, '0')
	term_ptr := b.block_instr2(.add, done, ptr_i8, out_data, total_len)
	b.block_instr2(.store, done, b.void_type, zero8, term_ptr)
	result := b.emit_make_string(done, out_data, total_len)
	b.block_instr1(.ret, done, b.void_type, result)
}

fn (mut b Builder) register_array_runtime_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)

	mut p3 := []TypeID{}
	p3 << b.i64_type
	p3 << b.i64_type
	p3 << b.i64_type
	array_new_id := b.register_synthetic_function('array_new', b.array_type, p3)
	b.generate_array_new_body(array_new_id)

	mut p2 := []TypeID{}
	p2 << b.array_type
	p2 << b.i64_type
	array_get_id := b.register_synthetic_function('array_get', ptr_i8, p2)
	b.generate_array_get_body(array_get_id)

	p3 = []TypeID{}
	p3 << b.array_type
	p3 << b.i64_type
	p3 << b.i64_type
	array_slice_id := b.register_synthetic_function('array_slice', b.array_type, p3)
	b.generate_array_slice_body(array_slice_id)

	p2 = []TypeID{}
	p2 << ptr_array
	p2 << ptr_i8
	array_push_id := b.register_synthetic_function('array_push', b.void_type, p2)
	b.generate_array_push_body(array_push_id)

	mut p3_push_many := []TypeID{}
	p3_push_many << ptr_array
	p3_push_many << ptr_i8
	p3_push_many << b.i64_type
	array_push_many_id := b.register_synthetic_function('array.push_many', b.void_type,
		p3_push_many)
	b.generate_array_push_many_body(array_push_many_id)

	mut p1 := []TypeID{}
	p1 << b.array_type
	array_clone_id := b.register_synthetic_function('array_clone', b.array_type, p1)
	b.generate_array_clone_body(array_clone_id)
}

fn (mut b Builder) register_panic_stub() {
	mut p1 := []TypeID{}
	p1 << b.str_type
	panic_id := b.register_synthetic_function('panic', b.void_type, p1)
	b.generate_panic_body(panic_id)
}

fn (mut b Builder) generate_panic_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	message := b.func_add_argument(func_id, b.str_type, 'message')
	if eprintln_id := b.fn_ids['eprintln'] {
		fn_ref := b.m.add_value(.func_ref, b.void_type, 'eprintln', eprintln_id)
		b.block_instr2(.call, entry, b.void_type, fn_ref, message)
	}
	if exit_id := b.fn_ids['exit'] {
		one := b.m.get_or_add_const(b.i64_type, '1')
		fn_ref := b.m.add_value(.func_ref, b.void_type, 'exit', exit_id)
		b.block_instr2(.call, entry, b.void_type, fn_ref, one)
	}
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) register_string_builder_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)

	mut p1 := []TypeID{}
	p1 << b.i64_type
	new_id := b.register_synthetic_function('strings.new_builder', b.array_type, p1)
	b.generate_builder_new_body(new_id)

	mut p2 := []TypeID{}
	p2 << ptr_builder
	p2 << b.str_type
	write_string_id :=
		b.register_synthetic_function('strings.Builder.write_string', b.void_type, p2)
	b.generate_builder_write_string_body(write_string_id, false)
	writeln_id := b.register_synthetic_function('strings.Builder.writeln', b.void_type, p2)
	b.generate_builder_write_string_body(writeln_id, true)

	p1 = []TypeID{}
	p1 << ptr_builder
	str_id := b.register_synthetic_function('strings.Builder.str', b.str_type, p1)
	b.generate_builder_str_body(str_id)
	free_id := b.register_synthetic_function('strings.Builder.free', b.void_type, p1)
	b.generate_builder_free_body(free_id)

	p2 = []TypeID{}
	p2 << ptr_builder
	p2 << b.i8_type
	write_u8_id := b.register_synthetic_function('strings.Builder.write_u8', b.void_type, p2)
	b.generate_builder_write_u8_body(write_u8_id)

	mut p3 := []TypeID{}
	p3 << ptr_builder
	p3 << ptr_i8
	p3 << b.i64_type
	write_ptr_id := b.register_synthetic_function('strings.Builder.write_ptr', b.void_type, p3)
	b.generate_builder_write_ptr_body(write_ptr_id)

	p2 = []TypeID{}
	p2 << ptr_builder
	p2 << b.array_type
	write_runes_id := b.register_synthetic_function('strings.Builder.write_runes', b.void_type, p2)
	b.generate_builder_free_body(write_runes_id)

	p2 = []TypeID{}
	p2 << ptr_builder
	p2 << b.i64_type
	last_n_id := b.register_synthetic_function('strings.Builder.last_n', b.str_type, p2)
	b.generate_builder_last_n_body(last_n_id)
}

fn (mut b Builder) generate_builder_new_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	initial_size := b.func_add_argument(func_id, b.i64_type, 'initial_size')
	one := b.m.get_or_add_const(b.i64_type, '1')
	zero := b.m.get_or_add_const(b.i64_type, '0')
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'array_new', b.fn_ids['array_new'])
	builder := b.block_instr4(.call, entry, b.array_type, fn_ref, one, zero, initial_size)
	b.block_instr1(.ret, entry, b.void_type, builder)
}

fn (mut b Builder) emit_builder_append(func_id int, entry BlockID, builder_ptr ValueID, src_ptr ValueID, add_len ValueID) BlockID {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	data_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 2)
	cap_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 3)
	old_len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	old_len := b.block_instr1(.zext, entry, b.i64_type, old_len32)
	cap32 := b.block_instr1(.load, entry, b.i32_type, cap_ptr)
	cap := b.block_instr1(.zext, entry, b.i64_type, cap32)
	needed := b.block_instr2(.add, entry, b.i64_type, old_len, add_len)
	needs_grow := b.block_instr2(.gt, entry, b.i1_type, needed, cap)

	blk_grow := b.m.add_block(func_id, 'builder_append_grow')
	blk_copy := b.m.add_block(func_id, 'builder_append_copy')
	b.block_instr3(.br, entry, b.void_type, needs_grow, ValueID(blk_grow), ValueID(blk_copy))

	two := b.m.get_or_add_const(b.i64_type, '2')
	old_data := b.block_instr1(.load, blk_grow, ptr_i8, data_ptr)
	double_needed := b.block_instr2(.mul, blk_grow, b.i64_type, needed, two)
	new_cap := b.block_instr2(.add, blk_grow, b.i64_type, double_needed, two)
	realloc_ref := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	new_data := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref, old_data, new_cap)
	b.block_instr2(.store, blk_grow, b.void_type, new_data, data_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, new_cap, cap_ptr)
	b.block_instr1(.jmp, blk_grow, b.void_type, ValueID(blk_copy))

	data := b.block_instr1(.load, blk_copy, ptr_i8, data_ptr)
	dest := b.block_instr2(.add, blk_copy, ptr_i8, data, old_len)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_copy, ptr_i8, memcpy_ref, dest, src_ptr, add_len)
	b.block_instr2(.store, blk_copy, b.void_type, needed, len_ptr)
	return blk_copy
}

fn (mut b Builder) generate_builder_write_string_body(func_id int, add_newline bool) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	s := b.func_add_argument(func_id, b.str_type, 's')

	alloca_s := b.block_instr0(.alloca, entry, ptr_string)
	b.block_instr2(.store, entry, b.void_type, s, alloca_s)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	str_ptr_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_s, zero)
	len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_s, len_off)
	str_ptr := b.block_instr1(.load, entry, ptr_i8, str_ptr_ptr)
	len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	len64 := b.block_instr1(.zext, entry, b.i64_type, len32)
	end_block := b.emit_builder_append(func_id, entry, builder_ptr, str_ptr, len64)
	if add_newline {
		nl := b.m.get_or_add_const(b.i8_type, '10')
		alloca_nl := b.block_instr0(.alloca, end_block, ptr_i8)
		b.block_instr2(.store, end_block, b.void_type, nl, alloca_nl)
		one := b.m.get_or_add_const(b.i64_type, '1')
		final_block := b.emit_builder_append(func_id, end_block, builder_ptr, alloca_nl, one)
		b.block_instr0(.ret, final_block, b.void_type)
	} else {
		b.block_instr0(.ret, end_block, b.void_type)
	}
}

fn (mut b Builder) generate_builder_write_ptr_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	src_ptr := b.func_add_argument(func_id, ptr_i8, 'ptr')
	len := b.func_add_argument(func_id, b.i64_type, 'len')
	end_block := b.emit_builder_append(func_id, entry, builder_ptr, src_ptr, len)
	b.block_instr0(.ret, end_block, b.void_type)
}

fn (mut b Builder) generate_builder_write_u8_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	ch := b.func_add_argument(func_id, b.i8_type, 'ch')
	alloca_ch := b.block_instr0(.alloca, entry, ptr_i8)
	b.block_instr2(.store, entry, b.void_type, ch, alloca_ch)
	one := b.m.get_or_add_const(b.i64_type, '1')
	end_block := b.emit_builder_append(func_id, entry, builder_ptr, alloca_ch, one)
	b.block_instr0(.ret, end_block, b.void_type)
}

fn (mut b Builder) generate_builder_str_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	alloca_s := b.block_instr0(.alloca, entry, ptr_string)
	data_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 2)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, entry, b.i64_type, len32)
	out_data_ptr := b.block_struct_field_ptr(entry, alloca_s, b.str_type, 0)
	out_len_ptr := b.block_struct_field_ptr(entry, alloca_s, b.str_type, 1)
	b.block_instr2(.store, entry, b.void_type, data, out_data_ptr)
	b.block_instr2(.store, entry, b.void_type, len, out_len_ptr)
	result := b.block_instr1(.load, entry, b.str_type, alloca_s)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_builder_last_n_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	n := b.func_add_argument(func_id, b.i64_type, 'n')
	alloca_s := b.block_instr0(.alloca, entry, ptr_string)
	data_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 2)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, entry, b.i64_type, len32)
	start := b.block_instr2(.sub, entry, b.i64_type, len, n)
	out_data := b.block_instr2(.add, entry, ptr_i8, data, start)
	out_data_ptr := b.block_struct_field_ptr(entry, alloca_s, b.str_type, 0)
	out_len_ptr := b.block_struct_field_ptr(entry, alloca_s, b.str_type, 1)
	b.block_instr2(.store, entry, b.void_type, out_data, out_data_ptr)
	b.block_instr2(.store, entry, b.void_type, n, out_len_ptr)
	result := b.block_instr1(.load, entry, b.str_type, alloca_s)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_builder_free_body(func_id int) {
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	_ := b.func_add_argument(func_id, ptr_builder, 'builder')
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) register_path_runtime_stubs() {
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	mut p1 := []TypeID{}
	p1 << ptr_builder
	normalize_id := b.register_synthetic_function('normalize_path_in_builder', b.void_type, p1)
	b.generate_builder_free_body(normalize_id)
}

fn (mut b Builder) register_map_runtime_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)

	mut p2 := []TypeID{}
	p2 << ptr_map
	p2 << ptr_i8
	find_id := b.register_synthetic_function('v3_map_find', b.i64_type, p2)
	b.generate_map_find_body(find_id)

	mut p6 := []TypeID{}
	for _ in 0 .. 6 {
		p6 << b.i64_type
	}
	new_id := b.register_synthetic_function('new_map', b.map_type, p6)
	b.generate_new_map_body(new_id)

	mut p3 := []TypeID{}
	p3 << ptr_map
	p3 << ptr_i8
	p3 << ptr_i8

	mut p5 := []TypeID{}
	p5 << ptr_map
	p5 << ptr_i8
	p5 << ptr_i8
	p5 << b.i64_type
	p5 << b.i64_type
	sized_set_id := b.register_synthetic_function('v3_map_set_sized', b.void_type, p5)
	b.generate_map_set_sized_body(sized_set_id)
	set_id := b.register_synthetic_function('map__set', b.void_type, p3)
	b.generate_map_set_default_body(set_id)

	p3 = []TypeID{}
	p3 << ptr_map
	p3 << ptr_i8
	p3 << ptr_i8
	get_id := b.register_synthetic_function('map__get', ptr_i8, p3)
	b.generate_map_get_body(get_id)
	get_check_id := b.register_synthetic_function('map__get_check', ptr_i8, p3)
	b.generate_map_get_check_body(get_check_id)
	get_or_set_id := b.register_synthetic_function('map__get_or_set', ptr_i8, p3)
	b.generate_map_get_body(get_or_set_id)

	p2 = []TypeID{}
	p2 << ptr_map
	p2 << ptr_i8
	exists_id := b.register_synthetic_function('map__exists', b.i1_type, p2)
	b.generate_map_exists_body(exists_id)

	mut p1_ptr := []TypeID{}
	p1_ptr << ptr_map
	clear_id := b.register_synthetic_function('map__clear', b.void_type, p1_ptr)
	b.generate_map_ptr_noop_body(clear_id)

	p2 = []TypeID{}
	p2 << ptr_map
	p2 << ptr_i8
	delete_id := b.register_synthetic_function('map__delete', b.void_type, p2)
	b.generate_map_delete_body(delete_id)

	mut p1_map := []TypeID{}
	p1_map << b.map_type
	clone_id := b.register_synthetic_function('map__clone', b.map_type, p1_map)
	b.generate_map_clone_body(clone_id)
}

fn (mut b Builder) generate_map_ptr_noop_body(func_id int) {
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	_ := b.func_add_argument(func_id, ptr_map, 'm')
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) generate_map_delete_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	_ := b.func_add_argument(func_id, ptr_map, 'm')
	_ = b.func_add_argument(func_id, ptr_i8, 'key')
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) generate_map_clone_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	m := b.func_add_argument(func_id, b.map_type, 'm')
	b.block_instr1(.ret, entry, b.void_type, m)
}

fn (mut b Builder) register_u8_runtime_stubs() {
	mut p1 := []TypeID{}
	p1 << b.i8_type
	for name in ['u8.is_digit', 'u8.is_letter', 'u8.is_alnum', 'u8.is_capital'] {
		func_id := b.register_synthetic_function(name, b.i1_type, p1)
		b.generate_u8_predicate_body(func_id, name)
	}
}

fn (mut b Builder) generate_u8_predicate_body(func_id int, name string) {
	entry := b.m.add_block(func_id, 'entry')
	c := b.func_add_argument(func_id, b.i8_type, 'c')
	digit := b.u8_in_range(entry, c, `0`, `9`)
	lower := b.u8_in_range(entry, c, `a`, `z`)
	upper := b.u8_in_range(entry, c, `A`, `Z`)
	letter := b.block_instr2(.or_, entry, b.i1_type, lower, upper)
	result := match name {
		'u8.is_digit' {
			digit
		}
		'u8.is_letter' {
			letter
		}
		'u8.is_alnum' {
			b.block_instr2(.or_, entry, b.i1_type, digit, letter)
		}
		else {
			upper
		}
	}

	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) u8_in_range(block_id BlockID, c ValueID, low u8, high u8) ValueID {
	low_v := b.m.get_or_add_const(b.i8_type, '${int(low)}')
	high_v := b.m.get_or_add_const(b.i8_type, '${int(high)}')
	ge_low := b.block_instr2(.ge, block_id, b.i1_type, c, low_v)
	le_high := b.block_instr2(.le, block_id, b.i1_type, c, high_v)
	return b.block_instr2(.and_, block_id, b.i1_type, ge_low, le_high)
}

fn (mut b Builder) register_heap_tracking_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut p2 := []TypeID{}
	p2 << ptr_i8
	p2 << b.i64_type
	alloc_id := b.register_synthetic_function('_ht_alloc', b.void_type, p2)
	b.generate_void_noop_body(alloc_id)
	mut p1 := []TypeID{}
	p1 << ptr_i8
	free_id := b.register_synthetic_function('_ht_free', b.void_type, p1)
	b.generate_void_noop_body(free_id)
}

fn (mut b Builder) generate_void_noop_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) register_process_capture_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut p3 := []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << ptr_i8
	for name in ['v_os_execute_capture_start', 'v_os_exec_capture_start'] {
		func_id := b.register_synthetic_function(name, b.i64_type, p3)
		b.generate_const_i64_body(func_id, '1')
	}
}

fn (mut b Builder) generate_const_i64_body(func_id int, value string) {
	entry := b.m.add_block(func_id, 'entry')
	result := b.m.get_or_add_const(b.i64_type, value)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_array_string_stubs() {
	mut p1 := []TypeID{}
	p1 << b.array_type
	array_str_id := b.register_synthetic_function('Array_str', b.str_type, p1)
	b.generate_const_string_body(array_str_id, '[]')
	bytestr_id := b.register_synthetic_function('bytestr', b.str_type, p1)
	b.generate_array_bytestr_body(bytestr_id)

	mut p2 := []TypeID{}
	p2 << b.array_type
	p2 << b.str_type
	for name in ['array_string_join', 'Array_string__join'] {
		func_id := b.register_synthetic_function(name, b.str_type, p2)
		b.generate_const_string_body(func_id, '')
	}
}

fn (mut b Builder) generate_array_bytestr_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)
	data_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 2)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, entry, b.i64_type, len32)

	one := b.m.get_or_add_const(b.i64_type, '1')
	alloc_len := b.block_instr2(.add, entry, b.i64_type, len, one)
	malloc_ref := b.m.add_value(.func_ref, b.void_type, 'malloc', b.fn_ids['malloc'])
	out_data := b.block_instr2(.call, entry, ptr_i8, malloc_ref, alloc_len)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, entry, ptr_i8, memcpy_ref, out_data, data, len)
	zero8 := b.m.get_or_add_const(b.i8_type, '0')
	term_ptr := b.block_instr2(.add, entry, ptr_i8, out_data, len)
	b.block_instr2(.store, entry, b.void_type, zero8, term_ptr)

	result := b.emit_make_string(entry, out_data, len)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_ierror_stubs() {
	ptr_ierror := b.m.type_store.get_ptr(b.i64_type)
	mut p1 := []TypeID{}
	p1 << ptr_ierror
	msg_id := b.register_synthetic_function('IError.msg', b.str_type, p1)
	b.generate_ierror_msg_body(msg_id, ptr_ierror)
	code_id := b.register_synthetic_function('IError.code', b.i64_type, p1)
	b.generate_ierror_code_body(code_id, ptr_ierror)
}

fn (mut b Builder) generate_ierror_msg_body(func_id int, ptr_ierror TypeID) {
	entry := b.m.add_block(func_id, 'entry')
	_ := b.func_add_argument(func_id, ptr_ierror, 'err')
	result := b.m.add_value(.string_literal, b.str_type, '', 0)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_ierror_code_body(func_id int, ptr_ierror TypeID) {
	entry := b.m.add_block(func_id, 'entry')
	_ := b.func_add_argument(func_id, ptr_ierror, 'err')
	result := b.m.get_or_add_const(b.i64_type, '0')
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_fixed_array_contains_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut p3_string := []TypeID{}
	p3_string << ptr_i8
	p3_string << b.i64_type
	p3_string << b.str_type
	contains_string_id := b.register_synthetic_function('fixed_array_contains_string', b.i1_type,
		p3_string)
	b.generate_fixed_array_contains_string_body(contains_string_id)

	mut p3_int := []TypeID{}
	p3_int << ptr_i8
	p3_int << b.i64_type
	p3_int << b.i64_type
	contains_int_id := b.register_synthetic_function('fixed_array_contains_int', b.i1_type, p3_int)
	b.generate_const_bool_body(contains_int_id, false)
}

fn (mut b Builder) generate_fixed_array_contains_string_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, ptr_i8, 'arr')
	len := b.func_add_argument(func_id, b.i64_type, 'len')
	needle := b.func_add_argument(func_id, b.str_type, 'needle')
	alloca_i := b.block_instr0(.alloca, entry, ptr_i64)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	one := b.m.get_or_add_const(b.i64_type, '1')
	b.block_instr2(.store, entry, b.void_type, zero, alloca_i)

	blk_loop := b.m.add_block(func_id, 'fixed_array_contains_string_loop')
	blk_body := b.m.add_block(func_id, 'fixed_array_contains_string_body')
	blk_next := b.m.add_block(func_id, 'fixed_array_contains_string_next')
	blk_found := b.m.add_block(func_id, 'fixed_array_contains_string_found')
	blk_not_found := b.m.add_block(func_id, 'fixed_array_contains_string_not_found')
	b.block_instr1(.jmp, entry, b.void_type, ValueID(blk_loop))

	i := b.block_instr1(.load, blk_loop, b.i64_type, alloca_i)
	in_range := b.block_instr2(.lt, blk_loop, b.i1_type, i, len)
	b.block_instr3(.br, blk_loop, b.void_type, in_range, ValueID(blk_body), ValueID(blk_not_found))

	stride := b.m.get_or_add_const(b.i64_type, '${b.m.type_size(b.str_type)}')
	offset := b.block_instr2(.mul, blk_body, b.i64_type, i, stride)
	slot := b.block_instr2(.add, blk_body, ptr_i8, arr, offset)
	slot_string_ptr := b.block_instr1(.bitcast, blk_body, ptr_string, slot)
	slot_string := b.block_instr1(.load, blk_body, b.str_type, slot_string_ptr)
	eq_ref := b.m.add_value(.func_ref, b.void_type, 'string__eq', b.fn_ids['string__eq'])
	is_eq := b.block_instr3(.call, blk_body, b.i1_type, eq_ref, slot_string, needle)
	b.block_instr3(.br, blk_body, b.void_type, is_eq, ValueID(blk_found), ValueID(blk_next))

	next_i := b.block_instr2(.add, blk_next, b.i64_type, i, one)
	b.block_instr2(.store, blk_next, b.void_type, next_i, alloca_i)
	b.block_instr1(.jmp, blk_next, b.void_type, ValueID(blk_loop))

	true_value := b.m.get_or_add_const(b.i1_type, '1')
	false_value := b.m.get_or_add_const(b.i1_type, '0')
	b.block_instr1(.ret, blk_found, b.void_type, true_value)
	b.block_instr1(.ret, blk_not_found, b.void_type, false_value)
}

fn (mut b Builder) generate_const_bool_body(func_id int, value bool) {
	entry := b.m.add_block(func_id, 'entry')
	result := b.m.get_or_add_const(b.i1_type, if value { '1' } else { '0' })
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_array_contains_stubs() {
	mut p2_string := []TypeID{}
	p2_string << b.array_type
	p2_string << b.str_type
	index_string_id := b.register_synthetic_function('array_index_string', b.i64_type, p2_string)
	b.generate_array_index_string_body(index_string_id)
	contains_string_id := b.register_synthetic_function('array_contains_string', b.i1_type,
		p2_string)
	b.generate_array_contains_from_index_body(contains_string_id, 'array_index_string', b.str_type)

	mut p2_int := []TypeID{}
	p2_int << b.array_type
	p2_int << b.i64_type
	index_int_id := b.register_synthetic_function('array_index_int', b.i64_type, p2_int)
	b.generate_array_index_int_body(index_int_id)
	contains_int_id := b.register_synthetic_function('array_contains_int', b.i1_type, p2_int)
	b.generate_array_contains_from_index_body(contains_int_id, 'array_index_int', b.i64_type)
}

fn (mut b Builder) generate_array_contains_from_index_body(func_id int, index_name string, needle_type TypeID) {
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')
	needle := b.func_add_argument(func_id, needle_type, 'needle')
	index_ref := b.m.add_value(.func_ref, b.void_type, index_name, b.fn_ids[index_name])
	idx := b.block_instr3(.call, entry, b.i64_type, index_ref, arr, needle)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	found := b.block_instr2(.ge, entry, b.i1_type, idx, zero)
	b.block_instr1(.ret, entry, b.void_type, found)
}

fn (mut b Builder) generate_array_index_string_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')
	needle := b.func_add_argument(func_id, b.str_type, 'needle')
	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	alloca_i := b.block_instr0(.alloca, entry, ptr_i64)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	one := b.m.get_or_add_const(b.i64_type, '1')
	b.block_instr2(.store, entry, b.void_type, zero, alloca_i)

	data_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 2)
	elem_size_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 5)
	blk_loop := b.m.add_block(func_id, 'array_index_string_loop')
	blk_body := b.m.add_block(func_id, 'array_index_string_body')
	blk_next := b.m.add_block(func_id, 'array_index_string_next')
	blk_found := b.m.add_block(func_id, 'array_index_string_found')
	blk_not_found := b.m.add_block(func_id, 'array_index_string_not_found')
	b.block_instr1(.jmp, entry, b.void_type, ValueID(blk_loop))

	i := b.block_instr1(.load, blk_loop, b.i64_type, alloca_i)
	len32 := b.block_instr1(.load, blk_loop, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, blk_loop, b.i64_type, len32)
	in_range := b.block_instr2(.lt, blk_loop, b.i1_type, i, len)
	b.block_instr3(.br, blk_loop, b.void_type, in_range, ValueID(blk_body), ValueID(blk_not_found))

	data := b.block_instr1(.load, blk_body, ptr_i8, data_ptr)
	elem_size32 := b.block_instr1(.load, blk_body, b.i32_type, elem_size_ptr)
	elem_size := b.block_instr1(.zext, blk_body, b.i64_type, elem_size32)
	offset := b.block_instr2(.mul, blk_body, b.i64_type, i, elem_size)
	slot := b.block_instr2(.add, blk_body, ptr_i8, data, offset)
	slot_string_ptr := b.block_instr1(.bitcast, blk_body, ptr_string, slot)
	slot_string := b.block_instr1(.load, blk_body, b.str_type, slot_string_ptr)
	eq_ref := b.m.add_value(.func_ref, b.void_type, 'string__eq', b.fn_ids['string__eq'])
	is_eq := b.block_instr3(.call, blk_body, b.i1_type, eq_ref, slot_string, needle)
	b.block_instr3(.br, blk_body, b.void_type, is_eq, ValueID(blk_found), ValueID(blk_next))

	next_i := b.block_instr2(.add, blk_next, b.i64_type, i, one)
	b.block_instr2(.store, blk_next, b.void_type, next_i, alloca_i)
	b.block_instr1(.jmp, blk_next, b.void_type, ValueID(blk_loop))

	b.block_instr1(.ret, blk_found, b.void_type, i)
	not_found := b.m.get_or_add_const(b.i64_type, '-1')
	b.block_instr1(.ret, blk_not_found, b.void_type, not_found)
}

fn (mut b Builder) generate_array_index_int_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')
	needle := b.func_add_argument(func_id, b.i64_type, 'needle')
	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	alloca_i := b.block_instr0(.alloca, entry, ptr_i64)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	one := b.m.get_or_add_const(b.i64_type, '1')
	b.block_instr2(.store, entry, b.void_type, zero, alloca_i)

	data_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 2)
	elem_size_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 5)
	blk_loop := b.m.add_block(func_id, 'array_index_int_loop')
	blk_body := b.m.add_block(func_id, 'array_index_int_body')
	blk_next := b.m.add_block(func_id, 'array_index_int_next')
	blk_found := b.m.add_block(func_id, 'array_index_int_found')
	blk_not_found := b.m.add_block(func_id, 'array_index_int_not_found')
	b.block_instr1(.jmp, entry, b.void_type, ValueID(blk_loop))

	i := b.block_instr1(.load, blk_loop, b.i64_type, alloca_i)
	len32 := b.block_instr1(.load, blk_loop, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, blk_loop, b.i64_type, len32)
	in_range := b.block_instr2(.lt, blk_loop, b.i1_type, i, len)
	b.block_instr3(.br, blk_loop, b.void_type, in_range, ValueID(blk_body), ValueID(blk_not_found))

	data := b.block_instr1(.load, blk_body, ptr_i8, data_ptr)
	elem_size32 := b.block_instr1(.load, blk_body, b.i32_type, elem_size_ptr)
	elem_size := b.block_instr1(.zext, blk_body, b.i64_type, elem_size32)
	offset := b.block_instr2(.mul, blk_body, b.i64_type, i, elem_size)
	slot := b.block_instr2(.add, blk_body, ptr_i8, data, offset)
	slot_i64_ptr := b.block_instr1(.bitcast, blk_body, ptr_i64, slot)
	slot_i64 := b.block_instr1(.load, blk_body, b.i64_type, slot_i64_ptr)
	is_eq := b.block_instr2(.eq, blk_body, b.i1_type, slot_i64, needle)
	b.block_instr3(.br, blk_body, b.void_type, is_eq, ValueID(blk_found), ValueID(blk_next))

	next_i := b.block_instr2(.add, blk_next, b.i64_type, i, one)
	b.block_instr2(.store, blk_next, b.void_type, next_i, alloca_i)
	b.block_instr1(.jmp, blk_next, b.void_type, ValueID(blk_loop))

	b.block_instr1(.ret, blk_found, b.void_type, i)
	not_found := b.m.get_or_add_const(b.i64_type, '-1')
	b.block_instr1(.ret, blk_not_found, b.void_type, not_found)
}

fn (mut b Builder) emit_map_state_alloc(block_id BlockID, key_size ValueID, val_size ValueID) ValueID {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_state := b.m.type_store.get_ptr(b.map_state_type)
	cap := b.m.get_or_add_const(b.i64_type, '8')
	one := b.m.get_or_add_const(b.i64_type, '1')
	zero := b.m.get_or_add_const(b.i64_type, '0')
	state_size := b.m.get_or_add_const(b.i64_type, '${b.m.type_size(b.map_state_type)}')
	calloc_ref := b.m.add_value(.func_ref, b.void_type, 'calloc', b.fn_ids['calloc'])
	state_raw := b.block_instr3(.call, block_id, ptr_i8, calloc_ref, one, state_size)
	state := b.block_instr1(.bitcast, block_id, ptr_state, state_raw)
	keys := b.block_instr3(.call, block_id, ptr_i8, calloc_ref, cap, key_size)
	vals := b.block_instr3(.call, block_id, ptr_i8, calloc_ref, cap, val_size)

	keys_ptr := b.map_state_field_ptr(block_id, state, 0)
	vals_ptr := b.map_state_field_ptr(block_id, state, 1)
	cap_ptr := b.map_state_field_ptr(block_id, state, 2)
	len_ptr := b.map_state_field_ptr(block_id, state, 3)
	key_size_ptr := b.map_state_field_ptr(block_id, state, 4)
	val_size_ptr := b.map_state_field_ptr(block_id, state, 5)
	b.block_instr2(.store, block_id, b.void_type, keys, keys_ptr)
	b.block_instr2(.store, block_id, b.void_type, vals, vals_ptr)
	b.block_instr2(.store, block_id, b.void_type, cap, cap_ptr)
	b.block_instr2(.store, block_id, b.void_type, zero, len_ptr)
	b.block_instr2(.store, block_id, b.void_type, key_size, key_size_ptr)
	b.block_instr2(.store, block_id, b.void_type, val_size, val_size_ptr)
	return state
}

fn (mut b Builder) map_state_ptr(block_id BlockID, map_ptr ValueID) ValueID {
	ptr_state := b.m.type_store.get_ptr(b.map_state_type)
	state_field_ptr := b.block_struct_field_ptr(block_id, map_ptr, b.map_type, 0)
	return b.block_instr1(.load, block_id, ptr_state, state_field_ptr)
}

fn (mut b Builder) map_state_field_ptr(block_id BlockID, state_ptr ValueID, field_idx int) ValueID {
	return b.block_struct_field_ptr(block_id, state_ptr, b.map_state_type, field_idx)
}

fn (mut b Builder) generate_new_map_body(func_id int) {
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	key_size := b.func_add_argument(func_id, b.i64_type, 'key_size')
	val_size := b.func_add_argument(func_id, b.i64_type, 'val_size')
	hash_fn := b.func_add_argument(func_id, b.i64_type, 'hash_fn')
	eq_fn := b.func_add_argument(func_id, b.i64_type, 'eq_fn')
	clone_fn := b.func_add_argument(func_id, b.i64_type, 'clone_fn')
	free_fn := b.func_add_argument(func_id, b.i64_type, 'free_fn')
	_ = hash_fn
	_ = eq_fn
	_ = clone_fn
	_ = free_fn

	alloca_m := b.block_instr0(.alloca, entry, ptr_map)
	state := b.emit_map_state_alloc(entry, key_size, val_size)
	state_ptr := b.block_struct_field_ptr(entry, alloca_m, b.map_type, 0)
	b.block_instr2(.store, entry, b.void_type, state, state_ptr)
	result := b.block_instr1(.load, entry, b.map_type, alloca_m)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_map_find_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_state := b.m.type_store.get_ptr(b.map_state_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')

	alloca_i := b.block_instr0(.alloca, entry, ptr_i64)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	b.block_instr2(.store, entry, b.void_type, zero, alloca_i)
	state := b.map_state_ptr(entry, map_ptr)
	zero_state := b.m.get_or_add_const(ptr_state, '0')
	has_state := b.block_instr2(.ne, entry, b.i1_type, state, zero_state)
	keys_ptr := b.map_state_field_ptr(entry, state, 0)
	len_ptr := b.map_state_field_ptr(entry, state, 3)
	key_size_ptr := b.map_state_field_ptr(entry, state, 4)

	blk_loop := b.m.add_block(func_id, 'map_find_loop')
	blk_body := b.m.add_block(func_id, 'map_find_body')
	blk_string_cmp := b.m.add_block(func_id, 'map_find_string_cmp')
	blk_mem_cmp := b.m.add_block(func_id, 'map_find_mem_cmp')
	blk_found := b.m.add_block(func_id, 'map_find_found')
	blk_next := b.m.add_block(func_id, 'map_find_next')
	blk_not_found := b.m.add_block(func_id, 'map_find_not_found')
	b.block_instr3(.br, entry, b.void_type, has_state, ValueID(blk_loop), ValueID(blk_not_found))

	i := b.block_instr1(.load, blk_loop, b.i64_type, alloca_i)
	len := b.block_instr1(.load, blk_loop, b.i64_type, len_ptr)
	in_range := b.block_instr2(.lt, blk_loop, b.i1_type, i, len)
	b.block_instr3(.br, blk_loop, b.void_type, in_range, ValueID(blk_body), ValueID(blk_not_found))

	keys := b.block_instr1(.load, blk_body, ptr_i8, keys_ptr)
	key_size := b.block_instr1(.load, blk_body, b.i64_type, key_size_ptr)
	offset := b.block_instr2(.mul, blk_body, b.i64_type, i, key_size)
	slot_key := b.block_instr2(.add, blk_body, ptr_i8, keys, offset)
	string_key_size := b.m.get_or_add_const(b.i64_type, '16')
	is_string_key := b.block_instr2(.eq, blk_body, b.i1_type, key_size, string_key_size)
	b.block_instr3(.br, blk_body, b.void_type, is_string_key, ValueID(blk_string_cmp),
		ValueID(blk_mem_cmp))

	slot_string_ptr := b.block_instr1(.bitcast, blk_string_cmp, ptr_string, slot_key)
	key_string_ptr := b.block_instr1(.bitcast, blk_string_cmp, ptr_string, key_ptr)
	slot_string := b.block_instr1(.load, blk_string_cmp, b.str_type, slot_string_ptr)
	key_string := b.block_instr1(.load, blk_string_cmp, b.str_type, key_string_ptr)
	eq_ref := b.m.add_value(.func_ref, b.void_type, 'fast_string_eq', b.fn_ids['fast_string_eq'])
	string_eq := b.block_instr3(.call, blk_string_cmp, b.i1_type, eq_ref, slot_string, key_string)
	b.block_instr3(.br, blk_string_cmp, b.void_type, string_eq, ValueID(blk_found),
		ValueID(blk_next))

	memcmp_ref := b.m.add_value(.func_ref, b.void_type, 'memcmp', b.fn_ids['memcmp'])
	cmp := b.block_instr4(.call, blk_mem_cmp, b.i64_type, memcmp_ref, slot_key, key_ptr, key_size)
	mem_eq := b.block_instr2(.eq, blk_mem_cmp, b.i1_type, cmp, zero)
	b.block_instr3(.br, blk_mem_cmp, b.void_type, mem_eq, ValueID(blk_found), ValueID(blk_next))

	b.block_instr1(.ret, blk_found, b.void_type, i)

	one := b.m.get_or_add_const(b.i64_type, '1')
	next_i := b.block_instr2(.add, blk_next, b.i64_type, i, one)
	b.block_instr2(.store, blk_next, b.void_type, next_i, alloca_i)
	b.block_instr1(.jmp, blk_next, b.void_type, ValueID(blk_loop))

	not_found := b.m.get_or_add_const(b.i64_type, '-1')
	b.block_instr1(.ret, blk_not_found, b.void_type, not_found)
}

fn (mut b Builder) generate_map_exists_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	find_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_find', b.fn_ids['v3_map_find'])
	idx := b.block_instr3(.call, entry, b.i64_type, find_ref, map_ptr, key_ptr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	found := b.block_instr2(.ge, entry, b.i1_type, idx, zero)
	b.block_instr1(.ret, entry, b.void_type, found)
}

fn (mut b Builder) generate_map_get_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	zero_ptr := b.func_add_argument(func_id, ptr_i8, 'zero')
	find_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_find', b.fn_ids['v3_map_find'])
	idx := b.block_instr3(.call, entry, b.i64_type, find_ref, map_ptr, key_ptr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	found := b.block_instr2(.ge, entry, b.i1_type, idx, zero)

	blk_found := b.m.add_block(func_id, 'map_get_found')
	blk_missing := b.m.add_block(func_id, 'map_get_missing')
	b.block_instr3(.br, entry, b.void_type, found, ValueID(blk_found), ValueID(blk_missing))

	state := b.map_state_ptr(blk_found, map_ptr)
	vals_ptr := b.map_state_field_ptr(blk_found, state, 1)
	val_size_ptr := b.map_state_field_ptr(blk_found, state, 5)
	vals := b.block_instr1(.load, blk_found, ptr_i8, vals_ptr)
	val_size := b.block_instr1(.load, blk_found, b.i64_type, val_size_ptr)
	offset := b.block_instr2(.mul, blk_found, b.i64_type, idx, val_size)
	result := b.block_instr2(.add, blk_found, ptr_i8, vals, offset)
	b.block_instr1(.ret, blk_found, b.void_type, result)

	b.block_instr1(.ret, blk_missing, b.void_type, zero_ptr)
}

fn (mut b Builder) generate_map_get_check_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	_ = b.func_add_argument(func_id, ptr_i8, 'zero')
	find_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_find', b.fn_ids['v3_map_find'])
	idx := b.block_instr3(.call, entry, b.i64_type, find_ref, map_ptr, key_ptr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	found := b.block_instr2(.ge, entry, b.i1_type, idx, zero)

	blk_found := b.m.add_block(func_id, 'map_get_check_found')
	blk_missing := b.m.add_block(func_id, 'map_get_check_missing')
	b.block_instr3(.br, entry, b.void_type, found, ValueID(blk_found), ValueID(blk_missing))

	state := b.map_state_ptr(blk_found, map_ptr)
	vals_ptr := b.map_state_field_ptr(blk_found, state, 1)
	val_size_ptr := b.map_state_field_ptr(blk_found, state, 5)
	vals := b.block_instr1(.load, blk_found, ptr_i8, vals_ptr)
	val_size := b.block_instr1(.load, blk_found, b.i64_type, val_size_ptr)
	offset := b.block_instr2(.mul, blk_found, b.i64_type, idx, val_size)
	result := b.block_instr2(.add, blk_found, ptr_i8, vals, offset)
	b.block_instr1(.ret, blk_found, b.void_type, result)

	null_ptr := b.m.get_or_add_const(ptr_i8, '0')
	b.block_instr1(.ret, blk_missing, b.void_type, null_ptr)
}

fn (mut b Builder) generate_map_set_default_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	val_ptr := b.func_add_argument(func_id, ptr_i8, 'val')
	key_size := b.m.get_or_add_const(b.i64_type, '16')
	val_size := b.m.get_or_add_const(b.i64_type, '8')
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_set_sized',
		b.fn_ids['v3_map_set_sized'])
	mut args := []ValueID{}
	args << fn_ref
	args << map_ptr
	args << key_ptr
	args << val_ptr
	args << key_size
	args << val_size
	b.m.add_instr(.call, entry, b.void_type, args)
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) generate_map_set_sized_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	ptr_state := b.m.type_store.get_ptr(b.map_state_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	val_ptr := b.func_add_argument(func_id, ptr_i8, 'val')
	key_size_arg := b.func_add_argument(func_id, b.i64_type, 'key_size')
	val_size_arg := b.func_add_argument(func_id, b.i64_type, 'val_size')
	zero := b.m.get_or_add_const(b.i64_type, '0')

	state_slot := b.block_instr0(.alloca, entry, b.m.type_store.get_ptr(ptr_state))
	state_field_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 0)
	old_state := b.block_instr1(.load, entry, ptr_state, state_field_ptr)
	b.block_instr2(.store, entry, b.void_type, old_state, state_slot)
	zero_state := b.m.get_or_add_const(ptr_state, '0')
	has_state := b.block_instr2(.ne, entry, b.i1_type, old_state, zero_state)

	blk_init := b.m.add_block(func_id, 'map_set_init')
	blk_ready := b.m.add_block(func_id, 'map_set_ready')
	blk_update := b.m.add_block(func_id, 'map_set_update')
	blk_insert := b.m.add_block(func_id, 'map_set_insert')
	b.block_instr3(.br, entry, b.void_type, has_state, ValueID(blk_ready), ValueID(blk_init))

	new_state := b.emit_map_state_alloc(blk_init, key_size_arg, val_size_arg)
	b.block_instr2(.store, blk_init, b.void_type, new_state, state_field_ptr)
	b.block_instr2(.store, blk_init, b.void_type, new_state, state_slot)
	b.block_instr1(.jmp, blk_init, b.void_type, ValueID(blk_ready))

	state := b.block_instr1(.load, blk_ready, ptr_state, state_slot)
	keys_ptr := b.map_state_field_ptr(blk_ready, state, 0)
	vals_ptr := b.map_state_field_ptr(blk_ready, state, 1)
	cap_ptr := b.map_state_field_ptr(blk_ready, state, 2)
	len_ptr := b.map_state_field_ptr(blk_ready, state, 3)
	key_size_ptr := b.map_state_field_ptr(blk_ready, state, 4)
	val_size_ptr := b.map_state_field_ptr(blk_ready, state, 5)

	find_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_find', b.fn_ids['v3_map_find'])
	idx := b.block_instr3(.call, blk_ready, b.i64_type, find_ref, map_ptr, key_ptr)
	found := b.block_instr2(.ge, blk_ready, b.i1_type, idx, zero)
	b.block_instr3(.br, blk_ready, b.void_type, found, ValueID(blk_update), ValueID(blk_insert))

	vals_update := b.block_instr1(.load, blk_update, ptr_i8, vals_ptr)
	val_size_update := b.block_instr1(.load, blk_update, b.i64_type, val_size_ptr)
	update_off := b.block_instr2(.mul, blk_update, b.i64_type, idx, val_size_update)
	update_dest := b.block_instr2(.add, blk_update, ptr_i8, vals_update, update_off)
	memcpy_ref_update := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_update, ptr_i8, memcpy_ref_update, update_dest, val_ptr,
		val_size_update)
	b.block_instr0(.ret, blk_update, b.void_type)

	len := b.block_instr1(.load, blk_insert, b.i64_type, len_ptr)
	cap := b.block_instr1(.load, blk_insert, b.i64_type, cap_ptr)
	needs_grow := b.block_instr2(.ge, blk_insert, b.i1_type, len, cap)
	blk_grow := b.m.add_block(func_id, 'map_set_grow')
	blk_store := b.m.add_block(func_id, 'map_set_store')
	b.block_instr3(.br, blk_insert, b.void_type, needs_grow, ValueID(blk_grow), ValueID(blk_store))

	two := b.m.get_or_add_const(b.i64_type, '2')
	eight := b.m.get_or_add_const(b.i64_type, '8')
	key_size_grow := b.block_instr1(.load, blk_grow, b.i64_type, key_size_ptr)
	val_size_grow := b.block_instr1(.load, blk_grow, b.i64_type, val_size_ptr)
	keys_old := b.block_instr1(.load, blk_grow, ptr_i8, keys_ptr)
	vals_old := b.block_instr1(.load, blk_grow, ptr_i8, vals_ptr)
	double_cap := b.block_instr2(.mul, blk_grow, b.i64_type, cap, two)
	new_cap := b.block_instr2(.add, blk_grow, b.i64_type, double_cap, eight)
	key_bytes := b.block_instr2(.mul, blk_grow, b.i64_type, new_cap, key_size_grow)
	val_bytes := b.block_instr2(.mul, blk_grow, b.i64_type, new_cap, val_size_grow)
	realloc_ref_keys := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	realloc_ref_vals := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	keys_new := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref_keys, keys_old, key_bytes)
	vals_new := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref_vals, vals_old, val_bytes)
	b.block_instr2(.store, blk_grow, b.void_type, keys_new, keys_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, vals_new, vals_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, new_cap, cap_ptr)
	b.block_instr1(.jmp, blk_grow, b.void_type, ValueID(blk_store))

	keys := b.block_instr1(.load, blk_store, ptr_i8, keys_ptr)
	vals := b.block_instr1(.load, blk_store, ptr_i8, vals_ptr)
	key_size := b.block_instr1(.load, blk_store, b.i64_type, key_size_ptr)
	val_size := b.block_instr1(.load, blk_store, b.i64_type, val_size_ptr)
	key_off := b.block_instr2(.mul, blk_store, b.i64_type, len, key_size)
	val_off := b.block_instr2(.mul, blk_store, b.i64_type, len, val_size)
	key_dest := b.block_instr2(.add, blk_store, ptr_i8, keys, key_off)
	val_dest := b.block_instr2(.add, blk_store, ptr_i8, vals, val_off)
	memcpy_ref_key := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	memcpy_ref_val := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_store, ptr_i8, memcpy_ref_key, key_dest, key_ptr, key_size)
	b.block_instr4(.call, blk_store, ptr_i8, memcpy_ref_val, val_dest, val_ptr, val_size)
	one := b.m.get_or_add_const(b.i64_type, '1')
	new_len := b.block_instr2(.add, blk_store, b.i64_type, len, one)
	b.block_instr2(.store, blk_store, b.void_type, new_len, len_ptr)
	b.block_instr0(.ret, blk_store, b.void_type)
}

fn (mut b Builder) generate_array_new_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_ptr_i8 := b.m.type_store.get_ptr(ptr_i8)
	entry := b.m.add_block(func_id, 'entry')
	elem_size := b.func_add_argument(func_id, b.i64_type, 'elem_size')
	len := b.func_add_argument(func_id, b.i64_type, 'len')
	cap := b.func_add_argument(func_id, b.i64_type, 'cap')

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	alloca_cap := b.block_instr0(.alloca, entry, ptr_i64)
	alloca_data := b.block_instr0(.alloca, entry, ptr_ptr_i8)
	cap_lt_len := b.block_instr2(.lt, entry, b.i1_type, cap, len)

	blk_use_len := b.m.add_block(func_id, 'array_new_use_len')
	blk_use_cap := b.m.add_block(func_id, 'array_new_use_cap')
	blk_init := b.m.add_block(func_id, 'array_new_init')
	b.block_instr3(.br, entry, b.void_type, cap_lt_len, ValueID(blk_use_len), ValueID(blk_use_cap))

	b.block_instr2(.store, blk_use_len, b.void_type, len, alloca_cap)
	b.block_instr1(.jmp, blk_use_len, b.void_type, ValueID(blk_init))

	b.block_instr2(.store, blk_use_cap, b.void_type, cap, alloca_cap)
	b.block_instr1(.jmp, blk_use_cap, b.void_type, ValueID(blk_init))

	final_cap := b.block_instr1(.load, blk_init, b.i64_type, alloca_cap)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	has_cap := b.block_instr2(.gt, blk_init, b.i1_type, final_cap, zero)
	blk_alloc := b.m.add_block(func_id, 'array_new_alloc')
	blk_empty := b.m.add_block(func_id, 'array_new_empty')
	blk_fields := b.m.add_block(func_id, 'array_new_fields')
	b.block_instr3(.br, blk_init, b.void_type, has_cap, ValueID(blk_alloc), ValueID(blk_empty))

	fn_ref := b.m.add_value(.func_ref, b.void_type, 'calloc', b.fn_ids['calloc'])
	allocated_data := b.block_instr3(.call, blk_alloc, ptr_i8, fn_ref, final_cap, elem_size)
	b.block_instr2(.store, blk_alloc, b.void_type, allocated_data, alloca_data)
	b.block_instr1(.jmp, blk_alloc, b.void_type, ValueID(blk_fields))

	null_data := b.m.get_or_add_const(ptr_i8, '0')
	b.block_instr2(.store, blk_empty, b.void_type, null_data, alloca_data)
	b.block_instr1(.jmp, blk_empty, b.void_type, ValueID(blk_fields))

	data := b.block_instr1(.load, blk_fields, ptr_i8, alloca_data)
	data_ptr := b.block_struct_field_ptr(blk_fields, alloca_arr, b.array_type, 0)
	offset_ptr := b.block_struct_field_ptr(blk_fields, alloca_arr, b.array_type, 1)
	len_ptr := b.block_struct_field_ptr(blk_fields, alloca_arr, b.array_type, 2)
	cap_ptr := b.block_struct_field_ptr(blk_fields, alloca_arr, b.array_type, 3)
	flags_ptr := b.block_struct_field_ptr(blk_fields, alloca_arr, b.array_type, 4)
	elem_size_ptr := b.block_struct_field_ptr(blk_fields, alloca_arr, b.array_type, 5)
	b.block_instr2(.store, blk_fields, b.void_type, data, data_ptr)
	b.block_instr2(.store, blk_fields, b.void_type, zero, offset_ptr)
	b.block_instr2(.store, blk_fields, b.void_type, len, len_ptr)
	b.block_instr2(.store, blk_fields, b.void_type, final_cap, cap_ptr)
	b.block_instr2(.store, blk_fields, b.void_type, zero, flags_ptr)
	b.block_instr2(.store, blk_fields, b.void_type, elem_size, elem_size_ptr)

	arr := b.block_instr1(.load, blk_fields, b.array_type, alloca_arr)
	b.block_instr1(.ret, blk_fields, b.void_type, arr)
}

fn (mut b Builder) generate_array_get_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')
	idx := b.func_add_argument(func_id, b.i64_type, 'idx')

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)

	data_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 0)
	elem_size_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 5)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	elem_size32 := b.block_instr1(.load, entry, b.i32_type, elem_size_ptr)
	elem_size := b.block_instr1(.zext, entry, b.i64_type, elem_size32)
	offset := b.block_instr2(.mul, entry, b.i64_type, idx, elem_size)
	result := b.block_instr2(.add, entry, ptr_i8, data, offset)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_array_slice_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')
	start := b.func_add_argument(func_id, b.i64_type, 'start')
	end := b.func_add_argument(func_id, b.i64_type, 'end')

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	alloca_out := b.block_instr0(.alloca, entry, ptr_array)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)

	data_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 0)
	elem_size_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 5)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	elem_size32 := b.block_instr1(.load, entry, b.i32_type, elem_size_ptr)
	elem_size := b.block_instr1(.zext, entry, b.i64_type, elem_size32)
	offset := b.block_instr2(.mul, entry, b.i64_type, start, elem_size)
	slice_data := b.block_instr2(.add, entry, ptr_i8, data, offset)
	slice_len := b.block_instr2(.sub, entry, b.i64_type, end, start)
	zero := b.m.get_or_add_const(b.i64_type, '0')

	out_data_ptr := b.block_struct_field_ptr(entry, alloca_out, b.array_type, 0)
	out_offset_ptr := b.block_struct_field_ptr(entry, alloca_out, b.array_type, 1)
	out_len_ptr := b.block_struct_field_ptr(entry, alloca_out, b.array_type, 2)
	out_cap_ptr := b.block_struct_field_ptr(entry, alloca_out, b.array_type, 3)
	out_flags_ptr := b.block_struct_field_ptr(entry, alloca_out, b.array_type, 4)
	out_elem_size_ptr := b.block_struct_field_ptr(entry, alloca_out, b.array_type, 5)
	b.block_instr2(.store, entry, b.void_type, slice_data, out_data_ptr)
	b.block_instr2(.store, entry, b.void_type, zero, out_offset_ptr)
	b.block_instr2(.store, entry, b.void_type, slice_len, out_len_ptr)
	b.block_instr2(.store, entry, b.void_type, slice_len, out_cap_ptr)
	b.block_instr2(.store, entry, b.void_type, zero, out_flags_ptr)
	b.block_instr2(.store, entry, b.void_type, elem_size, out_elem_size_ptr)

	result := b.block_instr1(.load, entry, b.array_type, alloca_out)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_arguments_stub() {
	arguments_id := b.register_synthetic_function('arguments', b.array_type, []TypeID{})
	b.generate_arguments_body(arguments_id)
}

fn (mut b Builder) generate_arguments_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_ptr_i8 := b.m.type_store.get_ptr(ptr_i8)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)

	entry := b.m.add_block(func_id, 'entry')
	argc_global := b.vars['g_main_argc']
	argv_global := b.vars['g_main_argv']
	argc := b.block_instr1(.load, entry, b.i64_type, argc_global)
	argv := b.block_instr1(.load, entry, ptr_ptr_i8, argv_global)

	elem_size := b.m.get_or_add_const(b.i64_type, '${b.m.type_size(b.str_type)}')
	zero := b.m.get_or_add_const(b.i64_type, '0')
	one := b.m.get_or_add_const(b.i64_type, '1')
	ptr_size := b.m.get_or_add_const(b.i64_type, '8')
	new_ref := b.m.add_value(.func_ref, b.void_type, 'array_new', b.fn_ids['array_new'])
	arr := b.block_instr4(.call, entry, b.array_type, new_ref, elem_size, zero, argc)

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	alloca_i := b.block_instr0(.alloca, entry, ptr_i64)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)
	b.block_instr2(.store, entry, b.void_type, zero, alloca_i)

	loop := b.m.add_block(func_id, 'arguments_loop')
	body := b.m.add_block(func_id, 'arguments_body')
	done := b.m.add_block(func_id, 'arguments_done')
	b.block_instr1(.jmp, entry, b.void_type, ValueID(loop))

	i := b.block_instr1(.load, loop, b.i64_type, alloca_i)
	more := b.block_instr2(.lt, loop, b.i1_type, i, argc)
	b.block_instr3(.br, loop, b.void_type, more, ValueID(body), ValueID(done))

	argv_off := b.block_instr2(.mul, body, b.i64_type, i, ptr_size)
	argv_slot := b.block_instr2(.add, body, ptr_ptr_i8, argv, argv_off)
	cstr := b.block_instr1(.load, body, ptr_i8, argv_slot)
	tos_clone_ref := b.m.add_value(.func_ref, b.str_type, 'tos_clone', b.fn_ids['tos_clone'])
	arg_string := b.block_instr2(.call, body, b.str_type, tos_clone_ref, cstr)

	data_ptr := b.block_struct_field_ptr(body, alloca_arr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(body, alloca_arr, b.array_type, 2)
	data := b.block_instr1(.load, body, ptr_i8, data_ptr)
	elem_off := b.block_instr2(.mul, body, b.i64_type, i, elem_size)
	dest := b.block_instr2(.add, body, ptr_i8, data, elem_off)
	dest_string := b.block_instr1(.bitcast, body, ptr_string, dest)
	b.block_instr2(.store, body, b.void_type, arg_string, dest_string)
	next_i := b.block_instr2(.add, body, b.i64_type, i, one)
	b.block_instr2(.store, body, b.void_type, next_i, len_ptr)
	b.block_instr2(.store, body, b.void_type, next_i, alloca_i)
	b.block_instr1(.jmp, body, b.void_type, ValueID(loop))

	result := b.block_instr1(.load, done, b.array_type, alloca_arr)
	b.block_instr1(.ret, done, b.void_type, result)
}

fn (mut b Builder) generate_array_clone_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	alloca_clone := b.block_instr0(.alloca, entry, ptr_array)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)

	data_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 2)
	cap_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 3)
	elem_size_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 5)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, entry, b.i64_type, len32)
	cap32 := b.block_instr1(.load, entry, b.i32_type, cap_ptr)
	cap := b.block_instr1(.zext, entry, b.i64_type, cap32)
	elem_size32 := b.block_instr1(.load, entry, b.i32_type, elem_size_ptr)
	elem_size := b.block_instr1(.zext, entry, b.i64_type, elem_size32)

	new_ref := b.m.add_value(.func_ref, b.void_type, 'array_new', b.fn_ids['array_new'])
	clone := b.block_instr4(.call, entry, b.array_type, new_ref, elem_size, len, cap)
	b.block_instr2(.store, entry, b.void_type, clone, alloca_clone)

	clone_data_ptr := b.block_struct_field_ptr(entry, alloca_clone, b.array_type, 0)
	clone_data := b.block_instr1(.load, entry, ptr_i8, clone_data_ptr)
	copy_size := b.block_instr2(.mul, entry, b.i64_type, len, elem_size)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, entry, ptr_i8, memcpy_ref, clone_data, data, copy_size)
	result := b.block_instr1(.load, entry, b.array_type, alloca_clone)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_array_push_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr_ptr := b.func_add_argument(func_id, ptr_array, 'arr')
	elem_ptr := b.func_add_argument(func_id, ptr_i8, 'elem')

	data_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 2)
	cap_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 3)
	elem_size_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 5)
	len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, entry, b.i64_type, len32)
	cap32 := b.block_instr1(.load, entry, b.i32_type, cap_ptr)
	cap := b.block_instr1(.zext, entry, b.i64_type, cap32)
	needs_grow := b.block_instr2(.ge, entry, b.i1_type, len, cap)

	blk_grow := b.m.add_block(func_id, 'array_push_grow')
	blk_store := b.m.add_block(func_id, 'array_push_store')
	b.block_instr3(.br, entry, b.void_type, needs_grow, ValueID(blk_grow), ValueID(blk_store))

	two := b.m.get_or_add_const(b.i64_type, '2')
	old_data := b.block_instr1(.load, blk_grow, ptr_i8, data_ptr)
	elem_size_grow32 := b.block_instr1(.load, blk_grow, b.i32_type, elem_size_ptr)
	elem_size_grow := b.block_instr1(.zext, blk_grow, b.i64_type, elem_size_grow32)
	double_cap := b.block_instr2(.mul, blk_grow, b.i64_type, cap, two)
	new_cap := b.block_instr2(.add, blk_grow, b.i64_type, double_cap, two)
	new_size := b.block_instr2(.mul, blk_grow, b.i64_type, new_cap, elem_size_grow)
	realloc_ref := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	new_data := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref, old_data, new_size)
	b.block_instr2(.store, blk_grow, b.void_type, new_data, data_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, new_cap, cap_ptr)
	b.block_instr1(.jmp, blk_grow, b.void_type, ValueID(blk_store))

	data := b.block_instr1(.load, blk_store, ptr_i8, data_ptr)
	elem_size32 := b.block_instr1(.load, blk_store, b.i32_type, elem_size_ptr)
	elem_size := b.block_instr1(.zext, blk_store, b.i64_type, elem_size32)
	offset := b.block_instr2(.mul, blk_store, b.i64_type, len, elem_size)
	dest := b.block_instr2(.add, blk_store, ptr_i8, data, offset)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_store, ptr_i8, memcpy_ref, dest, elem_ptr, elem_size)
	one := b.m.get_or_add_const(b.i64_type, '1')
	new_len := b.block_instr2(.add, blk_store, b.i64_type, len, one)
	b.block_instr2(.store, blk_store, b.void_type, new_len, len_ptr)
	b.block_instr0(.ret, blk_store, b.void_type)
}

fn (mut b Builder) generate_array_push_many_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr_ptr := b.func_add_argument(func_id, ptr_array, 'arr')
	src_ptr := b.func_add_argument(func_id, ptr_i8, 'src')
	count := b.func_add_argument(func_id, b.i64_type, 'count')

	zero := b.m.get_or_add_const(b.i64_type, '0')
	has_items := b.block_instr2(.gt, entry, b.i1_type, count, zero)
	blk_check_cap := b.m.add_block(func_id, 'array_push_many_check_cap')
	blk_done := b.m.add_block(func_id, 'array_push_many_done')
	b.block_instr3(.br, entry, b.void_type, has_items, ValueID(blk_check_cap), ValueID(blk_done))

	data_ptr := b.block_struct_field_ptr(blk_check_cap, arr_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(blk_check_cap, arr_ptr, b.array_type, 2)
	cap_ptr := b.block_struct_field_ptr(blk_check_cap, arr_ptr, b.array_type, 3)
	elem_size_ptr := b.block_struct_field_ptr(blk_check_cap, arr_ptr, b.array_type, 5)
	len32 := b.block_instr1(.load, blk_check_cap, b.i32_type, len_ptr)
	len := b.block_instr1(.zext, blk_check_cap, b.i64_type, len32)
	cap32 := b.block_instr1(.load, blk_check_cap, b.i32_type, cap_ptr)
	cap := b.block_instr1(.zext, blk_check_cap, b.i64_type, cap32)
	new_len := b.block_instr2(.add, blk_check_cap, b.i64_type, len, count)
	needs_grow := b.block_instr2(.gt, blk_check_cap, b.i1_type, new_len, cap)

	blk_grow := b.m.add_block(func_id, 'array_push_many_grow')
	blk_copy := b.m.add_block(func_id, 'array_push_many_copy')
	b.block_instr3(.br, blk_check_cap, b.void_type, needs_grow, ValueID(blk_grow),
		ValueID(blk_copy))

	old_data := b.block_instr1(.load, blk_grow, ptr_i8, data_ptr)
	elem_size_grow32 := b.block_instr1(.load, blk_grow, b.i32_type, elem_size_ptr)
	elem_size_grow := b.block_instr1(.zext, blk_grow, b.i64_type, elem_size_grow32)
	two := b.m.get_or_add_const(b.i64_type, '2')
	new_cap_base := b.block_instr2(.mul, blk_grow, b.i64_type, new_len, two)
	new_cap := b.block_instr2(.add, blk_grow, b.i64_type, new_cap_base, two)
	new_size := b.block_instr2(.mul, blk_grow, b.i64_type, new_cap, elem_size_grow)
	realloc_ref := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	new_data := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref, old_data, new_size)
	b.block_instr2(.store, blk_grow, b.void_type, new_data, data_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, new_cap, cap_ptr)
	b.block_instr1(.jmp, blk_grow, b.void_type, ValueID(blk_copy))

	data := b.block_instr1(.load, blk_copy, ptr_i8, data_ptr)
	elem_size32 := b.block_instr1(.load, blk_copy, b.i32_type, elem_size_ptr)
	elem_size := b.block_instr1(.zext, blk_copy, b.i64_type, elem_size32)
	offset := b.block_instr2(.mul, blk_copy, b.i64_type, len, elem_size)
	dest := b.block_instr2(.add, blk_copy, ptr_i8, data, offset)
	copy_size := b.block_instr2(.mul, blk_copy, b.i64_type, count, elem_size)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_copy, ptr_i8, memcpy_ref, dest, src_ptr, copy_size)
	b.block_instr2(.store, blk_copy, b.void_type, new_len, len_ptr)
	b.block_instr0(.ret, blk_copy, b.void_type)

	b.block_instr0(.ret, blk_done, b.void_type)
}

fn (mut b Builder) register_string_eq_stub() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	func_id := b.register_synthetic_function('string__eq', b.i1_type, p2)
	b.generate_string_eq_body(func_id)
}

fn (mut b Builder) register_fast_string_eq_stub() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	func_id := b.register_synthetic_function('fast_string_eq', b.i1_type, p2)
	b.generate_string_eq_body(func_id)
}

fn (mut b Builder) register_string_lt_stub() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	func_id := b.register_synthetic_function('string__lt', b.i1_type, p2)
	b.generate_string_lt_body(func_id)
}

fn (mut b Builder) register_string_trim_stubs() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	trim_right_id := b.register_synthetic_function('string.trim_right', b.str_type, p2)
	b.generate_string_trim_right_body(trim_right_id)
}

fn (mut b Builder) generate_string_trim_right_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_i1 := b.m.type_store.get_ptr(b.i1_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	s := b.func_add_argument(func_id, b.str_type, 's')
	cutset := b.func_add_argument(func_id, b.str_type, 'cutset')

	alloca_s := b.block_instr0(.alloca, entry, ptr_string)
	alloca_cutset := b.block_instr0(.alloca, entry, ptr_string)
	alloca_end := b.block_instr0(.alloca, entry, ptr_i64)
	alloca_j := b.block_instr0(.alloca, entry, ptr_i64)
	alloca_found := b.block_instr0(.alloca, entry, ptr_i1)
	b.block_instr2(.store, entry, b.void_type, s, alloca_s)
	b.block_instr2(.store, entry, b.void_type, cutset, alloca_cutset)

	s_data_ptr := b.block_struct_field_ptr(entry, alloca_s, b.str_type, 0)
	s_len_ptr := b.block_struct_field_ptr(entry, alloca_s, b.str_type, 1)
	cut_data_ptr := b.block_struct_field_ptr(entry, alloca_cutset, b.str_type, 0)
	cut_len_ptr := b.block_struct_field_ptr(entry, alloca_cutset, b.str_type, 1)
	s_data := b.block_instr1(.load, entry, ptr_i8, s_data_ptr)
	s_len32 := b.block_instr1(.load, entry, b.i32_type, s_len_ptr)
	s_len := b.block_instr1(.zext, entry, b.i64_type, s_len32)
	cut_data := b.block_instr1(.load, entry, ptr_i8, cut_data_ptr)
	cut_len32 := b.block_instr1(.load, entry, b.i32_type, cut_len_ptr)
	cut_len := b.block_instr1(.zext, entry, b.i64_type, cut_len32)
	zero64 := b.m.get_or_add_const(b.i64_type, '0')
	one64 := b.m.get_or_add_const(b.i64_type, '1')
	false_val := b.m.get_or_add_const(b.i1_type, '0')
	true_val := b.m.get_or_add_const(b.i1_type, '1')
	b.block_instr2(.store, entry, b.void_type, s_len, alloca_end)

	loop := b.m.add_block(func_id, 'trim_right_loop')
	body := b.m.add_block(func_id, 'trim_right_body')
	cut_loop := b.m.add_block(func_id, 'trim_right_cut_loop')
	cut_body := b.m.add_block(func_id, 'trim_right_cut_body')
	cut_found := b.m.add_block(func_id, 'trim_right_cut_found')
	cut_next := b.m.add_block(func_id, 'trim_right_cut_next')
	after_cut := b.m.add_block(func_id, 'trim_right_after_cut')
	trim_one := b.m.add_block(func_id, 'trim_right_trim_one')
	done := b.m.add_block(func_id, 'trim_right_done')
	b.block_instr1(.jmp, entry, b.void_type, ValueID(loop))

	end_val := b.block_instr1(.load, loop, b.i64_type, alloca_end)
	has_chars := b.block_instr2(.gt, loop, b.i1_type, end_val, zero64)
	b.block_instr3(.br, loop, b.void_type, has_chars, ValueID(body), ValueID(done))

	last_idx := b.block_instr2(.sub, body, b.i64_type, end_val, one64)
	ch_ptr := b.block_instr2(.add, body, ptr_i8, s_data, last_idx)
	ch := b.block_instr1(.load, body, b.i8_type, ch_ptr)
	b.block_instr2(.store, body, b.void_type, false_val, alloca_found)
	b.block_instr2(.store, body, b.void_type, zero64, alloca_j)
	b.block_instr1(.jmp, body, b.void_type, ValueID(cut_loop))

	j := b.block_instr1(.load, cut_loop, b.i64_type, alloca_j)
	more_cut := b.block_instr2(.lt, cut_loop, b.i1_type, j, cut_len)
	b.block_instr3(.br, cut_loop, b.void_type, more_cut, ValueID(cut_body), ValueID(after_cut))

	cut_ch_ptr := b.block_instr2(.add, cut_body, ptr_i8, cut_data, j)
	cut_ch := b.block_instr1(.load, cut_body, b.i8_type, cut_ch_ptr)
	is_match := b.block_instr2(.eq, cut_body, b.i1_type, ch, cut_ch)
	b.block_instr3(.br, cut_body, b.void_type, is_match, ValueID(cut_found), ValueID(cut_next))

	b.block_instr2(.store, cut_found, b.void_type, true_val, alloca_found)
	b.block_instr1(.jmp, cut_found, b.void_type, ValueID(after_cut))

	next_j := b.block_instr2(.add, cut_next, b.i64_type, j, one64)
	b.block_instr2(.store, cut_next, b.void_type, next_j, alloca_j)
	b.block_instr1(.jmp, cut_next, b.void_type, ValueID(cut_loop))

	found := b.block_instr1(.load, after_cut, b.i1_type, alloca_found)
	b.block_instr3(.br, after_cut, b.void_type, found, ValueID(trim_one), ValueID(done))

	cur_end := b.block_instr1(.load, trim_one, b.i64_type, alloca_end)
	new_end := b.block_instr2(.sub, trim_one, b.i64_type, cur_end, one64)
	b.block_instr2(.store, trim_one, b.void_type, new_end, alloca_end)
	b.block_instr1(.jmp, trim_one, b.void_type, ValueID(loop))

	final_len := b.block_instr1(.load, done, b.i64_type, alloca_end)
	result := b.emit_make_string(done, s_data, final_len)
	b.block_instr1(.ret, done, b.void_type, result)
}

fn (mut b Builder) generate_string_eq_body(func_id int) {
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.str_type, 'a')
	param_b := b.func_add_argument(func_id, b.str_type, 'b')

	alloca_a := b.block_instr0(.alloca, entry, ptr_string)
	alloca_b := b.block_instr0(.alloca, entry, ptr_string)
	b.block_instr2(.store, entry, b.void_type, param_a, alloca_a)
	b.block_instr2(.store, entry, b.void_type, param_b, alloca_b)

	zero_64 := b.m.get_or_add_const(b.i64_type, '0')
	len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	a_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_a, zero_64)
	b_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_b, zero_64)
	a_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_a, len_off)
	b_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_b, len_off)
	a_str := b.block_instr1(.load, entry, ptr_i8, a_str_ptr)
	b_str := b.block_instr1(.load, entry, ptr_i8, b_str_ptr)
	a_len := b.block_instr1(.load, entry, b.i32_type, a_len_ptr)
	b_len := b.block_instr1(.load, entry, b.i32_type, b_len_ptr)
	len_eq := b.block_instr2(.eq, entry, b.i1_type, a_len, b_len)

	blk_cmp := b.m.add_block(func_id, 'string_eq_cmp')
	blk_false := b.m.add_block(func_id, 'string_eq_false')
	b.block_instr3(.br, entry, b.void_type, len_eq, ValueID(blk_cmp), ValueID(blk_false))

	false_val := b.m.get_or_add_const(b.i1_type, '0')
	b.block_instr1(.ret, blk_false, b.void_type, false_val)

	a_len64 := b.block_instr1(.zext, blk_cmp, b.i64_type, a_len)
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'memcmp', b.fn_ids['memcmp'])
	cmp := b.block_instr4(.call, blk_cmp, b.i64_type, fn_ref, a_str, b_str, a_len64)
	is_eq := b.block_instr2(.eq, blk_cmp, b.i1_type, cmp, zero_64)
	b.block_instr1(.ret, blk_cmp, b.void_type, is_eq)
}

fn (mut b Builder) generate_string_lt_body(func_id int) {
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.str_type, 'a')
	param_b := b.func_add_argument(func_id, b.str_type, 'b')

	alloca_a := b.block_instr0(.alloca, entry, ptr_string)
	alloca_b := b.block_instr0(.alloca, entry, ptr_string)
	alloca_min := b.block_instr0(.alloca, entry, ptr_i32)
	b.block_instr2(.store, entry, b.void_type, param_a, alloca_a)
	b.block_instr2(.store, entry, b.void_type, param_b, alloca_b)

	zero_64 := b.m.get_or_add_const(b.i64_type, '0')
	len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	a_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_a, zero_64)
	b_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_b, zero_64)
	a_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_a, len_off)
	b_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_b, len_off)
	a_str := b.block_instr1(.load, entry, ptr_i8, a_str_ptr)
	b_str := b.block_instr1(.load, entry, ptr_i8, b_str_ptr)
	a_len := b.block_instr1(.load, entry, b.i32_type, a_len_ptr)
	b_len := b.block_instr1(.load, entry, b.i32_type, b_len_ptr)
	a_shorter := b.block_instr2(.lt, entry, b.i1_type, a_len, b_len)

	blk_a_min := b.m.add_block(func_id, 'string_lt_a_min')
	blk_b_min := b.m.add_block(func_id, 'string_lt_b_min')
	blk_cmp := b.m.add_block(func_id, 'string_lt_cmp')
	blk_true := b.m.add_block(func_id, 'string_lt_true')
	blk_false := b.m.add_block(func_id, 'string_lt_false')
	blk_cmp_gt := b.m.add_block(func_id, 'string_lt_cmp_gt')
	blk_len := b.m.add_block(func_id, 'string_lt_len')
	b.block_instr3(.br, entry, b.void_type, a_shorter, ValueID(blk_a_min), ValueID(blk_b_min))

	b.block_instr2(.store, blk_a_min, b.void_type, a_len, alloca_min)
	b.block_instr1(.jmp, blk_a_min, b.void_type, ValueID(blk_cmp))

	b.block_instr2(.store, blk_b_min, b.void_type, b_len, alloca_min)
	b.block_instr1(.jmp, blk_b_min, b.void_type, ValueID(blk_cmp))

	min_len := b.block_instr1(.load, blk_cmp, b.i32_type, alloca_min)
	min_len64 := b.block_instr1(.zext, blk_cmp, b.i64_type, min_len)
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'memcmp', b.fn_ids['memcmp'])
	cmp := b.block_instr4(.call, blk_cmp, b.i64_type, fn_ref, a_str, b_str, min_len64)
	cmp_lt_zero := b.block_instr2(.lt, blk_cmp, b.i1_type, cmp, zero_64)
	b.block_instr3(.br, blk_cmp, b.void_type, cmp_lt_zero, ValueID(blk_true), ValueID(blk_cmp_gt))

	cmp_gt_zero := b.block_instr2(.gt, blk_cmp_gt, b.i1_type, cmp, zero_64)
	b.block_instr3(.br, blk_cmp_gt, b.void_type, cmp_gt_zero, ValueID(blk_false), ValueID(blk_len))

	true_val := b.m.get_or_add_const(b.i1_type, '1')
	false_val := b.m.get_or_add_const(b.i1_type, '0')
	b.block_instr1(.ret, blk_true, b.void_type, true_val)
	b.block_instr1(.ret, blk_false, b.void_type, false_val)

	len_lt := b.block_instr2(.lt, blk_len, b.i1_type, a_len, b_len)
	b.block_instr1(.ret, blk_len, b.void_type, len_lt)
}

fn (mut b Builder) generate_wymix_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.i64_type, 'a')
	param_b := b.func_add_argument(func_id, b.i64_type, 'b')
	result := b.wymix_inline(entry, param_a, param_b)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_wyhash64_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.i64_type, 'a')
	param_b := b.func_add_argument(func_id, b.i64_type, 'b')

	wyp0 := b.m.get_or_add_const(b.i64_type, '3257665815644502181')
	wyp1 := b.m.get_or_add_const(b.i64_type, '10067880064238660809')

	x := b.block_instr2(.xor, entry, b.i64_type, param_a, wyp0)
	y := b.block_instr2(.xor, entry, b.i64_type, param_b, wyp1)
	result := b.wymix_inline(entry, x, y)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) wymum_pair_inline(block_id BlockID, a ValueID, b_val ValueID) (ValueID, ValueID) {
	mask32 := b.m.get_or_add_const(b.i64_type, '4294967295')
	c32 := b.m.get_or_add_const(b.i64_type, '32')

	lo := b.block_instr2(.mul, block_id, b.i64_type, a, b_val)

	x0 := b.block_instr2(.and_, block_id, b.i64_type, a, mask32)
	x1 := b.block_instr2(.lshr, block_id, b.i64_type, a, c32)
	y0 := b.block_instr2(.and_, block_id, b.i64_type, b_val, mask32)
	y1 := b.block_instr2(.lshr, block_id, b.i64_type, b_val, c32)
	w0 := b.block_instr2(.mul, block_id, b.i64_type, x0, y0)
	x1y0 := b.block_instr2(.mul, block_id, b.i64_type, x1, y0)
	w0_hi := b.block_instr2(.lshr, block_id, b.i64_type, w0, c32)
	t := b.block_instr2(.add, block_id, b.i64_type, x1y0, w0_hi)
	t_lo := b.block_instr2(.and_, block_id, b.i64_type, t, mask32)
	x0y1 := b.block_instr2(.mul, block_id, b.i64_type, x0, y1)
	w1 := b.block_instr2(.add, block_id, b.i64_type, t_lo, x0y1)
	w2 := b.block_instr2(.lshr, block_id, b.i64_type, t, c32)
	x1y1 := b.block_instr2(.mul, block_id, b.i64_type, x1, y1)
	w1_hi := b.block_instr2(.lshr, block_id, b.i64_type, w1, c32)
	hi_tmp := b.block_instr2(.add, block_id, b.i64_type, x1y1, w2)
	hi := b.block_instr2(.add, block_id, b.i64_type, hi_tmp, w1_hi)

	return lo, hi
}

fn (mut b Builder) wymix_inline(block_id BlockID, a ValueID, b_val ValueID) ValueID {
	lo, hi := b.wymum_pair_inline(block_id, a, b_val)
	return b.block_instr2(.xor, block_id, b.i64_type, hi, lo)
}

fn (mut b Builder) generate_wyhash_body(func_id int) {
	ptr_u8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_u32 := b.m.type_store.get_ptr(b.i32_type)
	ptr_u64 := b.m.type_store.get_ptr(b.i64_type)

	entry := b.m.add_block(func_id, 'entry')
	param_key := b.func_add_argument(func_id, ptr_u8, 'key')
	param_len := b.func_add_argument(func_id, b.i64_type, 'len')
	param_seed := b.func_add_argument(func_id, b.i64_type, 'seed')
	_ := b.func_add_argument(func_id, ptr_u64, 'secret')

	wyp0 := b.m.get_or_add_const(b.i64_type, '3257665815644502181')
	wyp1 := b.m.get_or_add_const(b.i64_type, '10067880064238660809')

	seed_xor_s0 := b.block_instr2(.xor, entry, b.i64_type, param_seed, wyp0)
	seed_xor_s0_len := b.block_instr2(.xor, entry, b.i64_type, seed_xor_s0, param_len)
	seed_mix := b.wymix_inline(entry, seed_xor_s0_len, wyp1)
	seed_init := b.block_instr2(.xor, entry, b.i64_type, param_seed, seed_mix)

	alloca_a := b.block_instr0(.alloca, entry, ptr_u64)
	alloca_b := b.block_instr0(.alloca, entry, ptr_u64)
	alloca_seed := b.block_instr0(.alloca, entry, ptr_u64)

	zero_64 := b.m.get_or_add_const(b.i64_type, '0')
	one_64 := b.m.get_or_add_const(b.i64_type, '1')
	two_64 := b.m.get_or_add_const(b.i64_type, '2')
	three_64 := b.m.get_or_add_const(b.i64_type, '3')
	four_64 := b.m.get_or_add_const(b.i64_type, '4')
	eight_64 := b.m.get_or_add_const(b.i64_type, '8')
	sixteen_64 := b.m.get_or_add_const(b.i64_type, '16')
	c32 := b.m.get_or_add_const(b.i64_type, '32')

	b.block_instr2(.store, entry, b.void_type, zero_64, alloca_a)
	b.block_instr2(.store, entry, b.void_type, zero_64, alloca_b)
	b.block_instr2(.store, entry, b.void_type, seed_init, alloca_seed)

	blk_short := b.m.add_block(func_id, 'wyhash_short')
	blk_short_4_16 := b.m.add_block(func_id, 'wyhash_short_4_16')
	blk_short_0_3 := b.m.add_block(func_id, 'wyhash_short_0_3')
	blk_wyr3 := b.m.add_block(func_id, 'wyhash_wyr3')
	blk_long := b.m.add_block(func_id, 'wyhash_long')
	blk_final := b.m.add_block(func_id, 'wyhash_final')

	len_le_16 := b.block_instr2(.le, entry, b.i1_type, param_len, sixteen_64)
	b.block_instr3(.br, entry, b.void_type, len_le_16, ValueID(blk_short), ValueID(blk_long))

	len_ge_4 := b.block_instr2(.ge, blk_short, b.i1_type, param_len, four_64)
	b.block_instr3(.br, blk_short, b.void_type, len_ge_4, ValueID(blk_short_4_16),
		ValueID(blk_short_0_3))

	p_as_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, param_key)
	wyr4_0 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_as_u32)
	wyr4_0_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_0)

	len_shr3 := b.block_instr2(.lshr, blk_short_4_16, b.i64_type, param_len, three_64)
	off1 := b.block_instr2(.shl, blk_short_4_16, b.i64_type, len_shr3, two_64)

	p_off1 := b.block_instr2(.add, blk_short_4_16, ptr_u8, param_key, off1)
	p_off1_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, p_off1)
	wyr4_1 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_off1_u32)
	wyr4_1_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_1)

	wyr4_0_shifted := b.block_instr2(.shl, blk_short_4_16, b.i64_type, wyr4_0_64, c32)
	a_val := b.block_instr2(.or_, blk_short_4_16, b.i64_type, wyr4_0_shifted, wyr4_1_64)

	len_m4 := b.block_instr2(.sub, blk_short_4_16, b.i64_type, param_len, four_64)
	p_lm4 := b.block_instr2(.add, blk_short_4_16, ptr_u8, param_key, len_m4)
	p_lm4_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, p_lm4)
	wyr4_2 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_lm4_u32)
	wyr4_2_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_2)

	lm4_moff1 := b.block_instr2(.sub, blk_short_4_16, b.i64_type, len_m4, off1)
	p_lm4_moff1 := b.block_instr2(.add, blk_short_4_16, ptr_u8, param_key, lm4_moff1)
	p_lm4_moff1_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, p_lm4_moff1)
	wyr4_3 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_lm4_moff1_u32)
	wyr4_3_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_3)

	wyr4_2_shifted := b.block_instr2(.shl, blk_short_4_16, b.i64_type, wyr4_2_64, c32)
	b_val := b.block_instr2(.or_, blk_short_4_16, b.i64_type, wyr4_2_shifted, wyr4_3_64)

	b.block_instr2(.store, blk_short_4_16, b.void_type, a_val, alloca_a)
	b.block_instr2(.store, blk_short_4_16, b.void_type, b_val, alloca_b)
	b.block_instr1(.jmp, blk_short_4_16, b.void_type, ValueID(blk_final))

	len_gt_0 := b.block_instr2(.gt, blk_short_0_3, b.i1_type, param_len, zero_64)
	b.block_instr3(.br, blk_short_0_3, b.void_type, len_gt_0, ValueID(blk_wyr3), ValueID(blk_final))

	byte_0 := b.block_instr1(.load, blk_wyr3, b.i8_type, param_key)
	byte_0_64 := b.block_instr1(.zext, blk_wyr3, b.i64_type, byte_0)
	byte_0_shifted := b.block_instr2(.shl, blk_wyr3, b.i64_type, byte_0_64, sixteen_64)

	len_shr1 := b.block_instr2(.lshr, blk_wyr3, b.i64_type, param_len, one_64)
	p_mid := b.block_instr2(.add, blk_wyr3, ptr_u8, param_key, len_shr1)
	byte_mid := b.block_instr1(.load, blk_wyr3, b.i8_type, p_mid)
	byte_mid_64 := b.block_instr1(.zext, blk_wyr3, b.i64_type, byte_mid)
	byte_mid_shifted := b.block_instr2(.shl, blk_wyr3, b.i64_type, byte_mid_64, eight_64)

	len_m1 := b.block_instr2(.sub, blk_wyr3, b.i64_type, param_len, one_64)
	p_last := b.block_instr2(.add, blk_wyr3, ptr_u8, param_key, len_m1)
	byte_last := b.block_instr1(.load, blk_wyr3, b.i8_type, p_last)
	byte_last_64 := b.block_instr1(.zext, blk_wyr3, b.i64_type, byte_last)

	a_tmp := b.block_instr2(.or_, blk_wyr3, b.i64_type, byte_0_shifted, byte_mid_shifted)
	a_wyr3 := b.block_instr2(.or_, blk_wyr3, b.i64_type, a_tmp, byte_last_64)

	b.block_instr2(.store, blk_wyr3, b.void_type, a_wyr3, alloca_a)
	b.block_instr1(.jmp, blk_wyr3, b.void_type, ValueID(blk_final))

	p_as_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, param_key)
	wyr8_first := b.block_instr1(.load, blk_long, b.i64_type, p_as_u64)

	p_plus_8 := b.block_instr2(.add, blk_long, ptr_u8, param_key, eight_64)
	p_plus_8_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, p_plus_8)
	wyr8_second := b.block_instr1(.load, blk_long, b.i64_type, p_plus_8_u64)

	len_m16 := b.block_instr2(.sub, blk_long, b.i64_type, param_len, sixteen_64)
	p_end_16 := b.block_instr2(.add, blk_long, ptr_u8, param_key, len_m16)
	p_end_16_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, p_end_16)
	wyr8_end_16 := b.block_instr1(.load, blk_long, b.i64_type, p_end_16_u64)

	len_m8 := b.block_instr2(.sub, blk_long, b.i64_type, param_len, eight_64)
	p_end_8 := b.block_instr2(.add, blk_long, ptr_u8, param_key, len_m8)
	p_end_8_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, p_end_8)
	wyr8_end_8 := b.block_instr1(.load, blk_long, b.i64_type, p_end_8_u64)

	mix_a := b.block_instr2(.xor, blk_long, b.i64_type, wyr8_first, wyp1)
	seed_cur := b.block_instr1(.load, blk_long, b.i64_type, alloca_seed)
	mix_b := b.block_instr2(.xor, blk_long, b.i64_type, wyr8_second, seed_cur)
	seed_long := b.wymix_inline(blk_long, mix_a, mix_b)

	b.block_instr2(.store, blk_long, b.void_type, seed_long, alloca_seed)
	b.block_instr2(.store, blk_long, b.void_type, wyr8_end_16, alloca_a)
	b.block_instr2(.store, blk_long, b.void_type, wyr8_end_8, alloca_b)
	b.block_instr1(.jmp, blk_long, b.void_type, ValueID(blk_final))

	final_a := b.block_instr1(.load, blk_final, b.i64_type, alloca_a)
	final_b := b.block_instr1(.load, blk_final, b.i64_type, alloca_b)
	final_seed := b.block_instr1(.load, blk_final, b.i64_type, alloca_seed)

	final_a_xor := b.block_instr2(.xor, blk_final, b.i64_type, final_a, wyp1)
	final_b_xor := b.block_instr2(.xor, blk_final, b.i64_type, final_b, final_seed)

	mum_lo, mum_hi := b.wymum_pair_inline(blk_final, final_a_xor, final_b_xor)

	lo_xor_s0 := b.block_instr2(.xor, blk_final, b.i64_type, mum_lo, wyp0)
	lo_xor_s0_len := b.block_instr2(.xor, blk_final, b.i64_type, lo_xor_s0, param_len)
	hi_xor_s1 := b.block_instr2(.xor, blk_final, b.i64_type, mum_hi, wyp1)

	final_result := b.wymix_inline(blk_final, lo_xor_s0_len, hi_xor_s1)
	b.block_instr1(.ret, blk_final, b.void_type, final_result)
}

fn (mut b Builder) build_functions() {
	mut cur_module := ''
	for node in b.a.nodes {
		if node.kind == .module_decl {
			cur_module = node.value
			continue
		}
		if node.kind == .fn_decl {
			if b.skip_source_fn_in_module(node.value, cur_module) {
				continue
			}
			if b.used_fns.len > 0 && !b.fn_is_used(node.value) {
				continue
			}
			b.build_function(node, cur_module)
		}
	}
	if b.top_level_main {
		b.build_top_level_main()
	}
}

fn (b &Builder) fn_is_used(name string) bool {
	if name in b.used_fns {
		return true
	}
	if name.contains('__') && name.replace('__', '.') in b.used_fns {
		return true
	}
	if name.contains('.') {
		for used_name, _ in b.used_fns {
			normalized_used := used_name.replace('__', '.')
			if used_name.ends_with('.${name}') || normalized_used.ends_with('.${name}') {
				return true
			}
		}
	}
	if name.starts_with('array_') || name.starts_with('string__') || name.starts_with('strings__')
		|| name.starts_with('strconv__') || name.starts_with('IError.') {
		return true
	}
	if name in ['new_map', 'memdup', 'int_str', 'bool_str', 'print', 'println', 'eprint', 'eprintln',
		'exit', 'arguments', 'tos', 'tos2', 'tos3', 'tos_clone', 'cstring_to_vstring',
		'malloc_noscan', 'isnil', 'error', 'error_with_code', 'join_path_single'] {
		return true
	}
	return false
}

fn (mut b Builder) build_function(node flat.Node, module_name string) {
	func_id := b.fn_ids[node.value]
	b.cur_module = module_name
	b.cur_func = func_id
	b.vars = map[string]ValueID{}
	b.var_type_names = map[string]string{}

	for v in b.m.values {
		if v.kind == .global {
			b.vars[v.name] = v.id
		}
	}

	entry := b.m.add_block(func_id, 'entry')
	b.cur_block = entry

	for i in 0 .. node.children_count {
		child := b.a.child_node(&node, i)
		if child.kind == .param {
			typ := b.resolve_type_in_module(child.typ, module_name)
			param_val := b.m.add_value(.argument, typ, child.value, b.m.funcs[func_id].params.len)
			mut f := b.m.funcs[func_id]
			f.params << param_val
			b.m.funcs[func_id] = f

			alloca := b.emit0(.alloca, b.m.type_store.get_ptr(typ))
			b.emit2(.store, b.void_type, param_val, alloca)
			b.vars[child.value] = alloca
			b.var_type_names[child.value] = child.typ
		}
	}

	body_ids := b.fn_body_ids(node)
	for id in body_ids {
		b.build_stmt(id)
	}

	blk := b.m.blocks[b.cur_block]
	if blk.instrs.len == 0 || !b.is_terminator(blk.instrs.last()) {
		ret_type := b.m.funcs[func_id].typ
		if ret_type == b.void_type {
			b.emit0(.ret, b.void_type)
		}
	}
}

fn (mut b Builder) build_top_level_main() {
	func_id := b.fn_ids['main'] or { return }
	b.cur_module = 'main'
	b.cur_func = func_id
	b.vars = map[string]ValueID{}
	b.var_type_names = map[string]string{}
	for v in b.m.values {
		if v.kind == .global {
			b.vars[v.name] = v.id
		}
	}
	entry := b.m.add_block(func_id, 'entry')
	b.cur_block = entry

	for id in b.top_level_stmt_ids() {
		b.build_stmt(id)
	}

	blk := b.m.blocks[b.cur_block]
	if blk.instrs.len == 0 || !b.is_terminator(blk.instrs.last()) {
		b.emit0(.ret, b.void_type)
	}
}

fn (b &Builder) fn_body_ids(node flat.Node) []flat.NodeId {
	mut ids := []flat.NodeId{}
	for i in 0 .. node.children_count {
		child := b.a.child_node(&node, i)
		if child.kind != .param {
			ids << b.a.child(&node, i)
		}
	}
	return ids
}

fn (b &Builder) is_terminator(val_id ValueID) bool {
	if val_id <= 0 || val_id >= b.m.values.len {
		return false
	}
	v := b.m.values[val_id]
	if v.kind != .instruction {
		return false
	}
	instr := b.m.instrs[v.index]
	return instr.op == .ret || instr.op == .br || instr.op == .jmp
}

fn (mut b Builder) build_stmt(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.expr_stmt {
			expr_id := b.a.child(&node, 0)
			expr := b.a.nodes[int(expr_id)]
			if expr.kind == .infix && expr.op == .left_shift && expr.value == 'push' {
				b.build_array_push_expr(expr)
				return
			}
			b.build_expr(expr_id)
		}
		.decl_assign {
			b.build_decl_assign(node)
		}
		.assign {
			b.build_assign(node)
		}
		.selector_assign {
			b.build_selector_assign(node)
		}
		.index_assign {
			b.build_index_assign(node)
		}
		.return_stmt {
			if node.children_count > 0 {
				val := b.build_expr(b.a.child(&node, 0))
				b.emit1(.ret, b.void_type, val)
			} else {
				b.emit0(.ret, b.void_type)
			}
		}
		.for_stmt {
			b.build_for(node)
		}
		.break_stmt {
			if b.break_targets.len > 0 {
				target := b.break_targets.last()
				b.emit1(.jmp, b.void_type, ValueID(target))
			}
		}
		.continue_stmt {
			if b.continue_targets.len > 0 {
				target := b.continue_targets.last()
				b.emit1(.jmp, b.void_type, ValueID(target))
			}
		}
		.if_expr {
			b.build_if(node)
		}
		.block {
			for i in 0 .. node.children_count {
				b.build_stmt(b.a.child(&node, i))
			}
		}
		.assert_stmt {
			b.build_assert(node)
		}
		.empty {}
		else {
			eprintln('build_stmt: unsupported node kind: ${node.kind}')
		}
	}
}

fn (mut b Builder) build_decl_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := b.a.child(&node, i)
		rhs_id := b.a.child(&node, i + 1)
		lhs := b.a.nodes[int(lhs_id)]
		rhs_val := b.build_expr(rhs_id)
		rhs_type := b.value_type(rhs_val)
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(rhs_type))
		b.emit2(.store, b.void_type, rhs_val, alloca)
		if lhs.kind == .ident {
			b.vars[lhs.value] = alloca
			b.var_type_names[lhs.value] = b.declared_v_type_name(lhs_id, rhs_id)
		}
		i += 2
	}
}

fn (mut b Builder) build_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := b.a.child(&node, i)
		rhs_id := b.a.child(&node, i + 1)
		lhs := b.a.nodes[int(lhs_id)]

		if lhs.kind == .ident {
			if addr := b.vars[lhs.value] {
				if node.op == .assign {
					rhs_val := b.build_expr(rhs_id)
					b.emit2(.store, b.void_type, rhs_val, addr)
				} else {
					cur := b.emit1(.load, b.deref_type(addr), addr)
					rhs_val := b.build_expr(rhs_id)
					op := b.compound_to_op(node.op)
					result := b.emit2(op, b.value_type(cur), cur, rhs_val)
					b.emit2(.store, b.void_type, result, addr)
				}
			}
		}
		i += 2
	}
}

fn (mut b Builder) build_selector_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := b.a.child(&node, i)
		rhs_id := b.a.child(&node, i + 1)
		lhs := b.a.nodes[int(lhs_id)]

		if lhs.kind == .selector {
			base_id := b.a.child(&lhs, 0)
			base := b.a.nodes[int(base_id)]
			field_name := lhs.value

			if base.kind == .ident {
				if addr := b.vars[base.value] {
					field_ptr := b.get_field_ptr(addr, field_name)
					if node.op == .assign {
						rhs_val := b.build_expr(rhs_id)
						b.emit2(.store, b.void_type, rhs_val, field_ptr)
					} else {
						field_type := b.deref_type(field_ptr)
						cur := b.emit1(.load, field_type, field_ptr)
						rhs_val := b.build_expr(rhs_id)
						op := b.compound_to_op(node.op)
						result := b.emit2(op, field_type, cur, rhs_val)
						b.emit2(.store, b.void_type, result, field_ptr)
					}
				}
			}
		}
		i += 2
	}
}

fn (mut b Builder) build_index_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := b.a.child(&node, i)
		rhs_id := b.a.child(&node, i + 1)
		addr := b.build_lvalue_addr(lhs_id)
		if node.op == .assign {
			rhs_val := b.build_expr(rhs_id)
			b.emit2(.store, b.void_type, rhs_val, addr)
		} else {
			field_type := b.deref_type(addr)
			cur := b.emit1(.load, field_type, addr)
			rhs_val := b.build_expr(rhs_id)
			op := b.compound_to_op(node.op)
			result := b.emit2(op, field_type, cur, rhs_val)
			b.emit2(.store, b.void_type, result, addr)
		}
		i += 2
	}
}

fn (mut b Builder) build_for(node flat.Node) {
	init_id := b.a.child(&node, 0)
	cond_id := b.a.child(&node, 1)
	post_id := b.a.child(&node, 2)
	init_node := b.a.nodes[int(init_id)]
	cond_node := b.a.nodes[int(cond_id)]
	post_node := b.a.nodes[int(post_id)]

	if init_node.kind != .empty {
		b.build_stmt(init_id)
	}

	cond_block := b.m.add_block(b.cur_func, 'for_cond')
	body_block := b.m.add_block(b.cur_func, 'for_body')
	post_block := b.m.add_block(b.cur_func, 'for_post')
	exit_block := b.m.add_block(b.cur_func, 'for_exit')

	b.emit1(.jmp, b.void_type, ValueID(cond_block))
	b.cur_block = cond_block

	if cond_node.kind != .empty {
		cond_val := b.build_expr(cond_id)
		b.emit3(.br, b.void_type, cond_val, ValueID(body_block), ValueID(exit_block))
	} else {
		b.emit1(.jmp, b.void_type, ValueID(body_block))
	}

	b.cur_block = body_block
	b.break_targets << exit_block
	b.continue_targets << if post_node.kind != .empty { post_block } else { cond_block }

	for i in 3 .. node.children_count {
		b.build_stmt(b.a.child(&node, i))
	}
	b.break_targets.delete_last()
	b.continue_targets.delete_last()

	blk := b.m.blocks[b.cur_block]
	if blk.instrs.len == 0 || !b.is_terminator(blk.instrs.last()) {
		if post_node.kind != .empty {
			b.emit1(.jmp, b.void_type, ValueID(post_block))
		} else {
			b.emit1(.jmp, b.void_type, ValueID(cond_block))
		}
	}

	if post_node.kind != .empty {
		b.cur_block = post_block
		b.build_stmt(post_id)
		post_blk := b.m.blocks[b.cur_block]
		if post_blk.instrs.len == 0 || !b.is_terminator(post_blk.instrs.last()) {
			b.emit1(.jmp, b.void_type, ValueID(cond_block))
		}
	}

	b.cur_block = exit_block
}

fn (mut b Builder) build_if(node flat.Node) {
	cond_node := b.a.child_node(&node, 0)
	then_block := b.m.add_block(b.cur_func, 'if_then')
	merge_block := b.m.add_block(b.cur_func, 'if_merge')

	if cond_node.kind == .empty {
		b.emit1(.jmp, b.void_type, ValueID(then_block))
	} else {
		cond_val := b.build_expr(b.a.child(&node, 0))
		if node.children_count > 2 {
			else_block := b.m.add_block(b.cur_func, 'if_else')
			b.emit3(.br, b.void_type, cond_val, ValueID(then_block), ValueID(else_block))

			b.cur_block = else_block
			else_node := b.a.child_node(&node, 2)
			if else_node.kind == .if_expr {
				b.build_if(*else_node)
			} else if else_node.kind == .block {
				for i in 0 .. else_node.children_count {
					b.build_stmt(b.a.child(else_node, i))
				}
			}
			eblk := b.m.blocks[b.cur_block]
			if eblk.instrs.len == 0 || !b.is_terminator(eblk.instrs.last()) {
				b.emit1(.jmp, b.void_type, ValueID(merge_block))
			}
		} else {
			b.emit3(.br, b.void_type, cond_val, ValueID(then_block), ValueID(merge_block))
		}
	}

	b.cur_block = then_block
	then_node := b.a.child_node(&node, 1)
	for i in 0 .. then_node.children_count {
		b.build_stmt(b.a.child(then_node, i))
	}
	tblk := b.m.blocks[b.cur_block]
	if tblk.instrs.len == 0 || !b.is_terminator(tblk.instrs.last()) {
		b.emit1(.jmp, b.void_type, ValueID(merge_block))
	}

	b.cur_block = merge_block
}

fn (mut b Builder) build_assert(node flat.Node) {
	cond_val := b.build_expr(b.a.child(&node, 0))
	fail_block := b.m.add_block(b.cur_func, 'assert_fail')
	ok_block := b.m.add_block(b.cur_func, 'assert_ok')
	b.emit3(.br, b.void_type, cond_val, ValueID(ok_block), ValueID(fail_block))

	b.cur_block = fail_block
	if exit_fn := b.fn_ids['exit'] {
		one := b.m.get_or_add_const(b.i64_type, '1')
		fn_ref := b.m.add_value(.func_ref, b.void_type, 'exit', exit_fn)
		b.emit2(.call, b.void_type, fn_ref, one)
	}
	b.emit0(.ret, b.void_type)

	b.cur_block = ok_block
}

fn (mut b Builder) build_expr(id flat.NodeId) ValueID {
	if int(id) < 0 {
		return b.m.get_or_add_const(b.i64_type, '0')
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			return b.m.get_or_add_const(b.i64_type, node.value)
		}
		.bool_literal {
			val := if node.value == 'true' { '1' } else { '0' }
			return b.m.get_or_add_const(b.i1_type, val)
		}
		.string_literal {
			return b.m.add_value(.string_literal, b.str_type, node.value, 0)
		}
		.char_literal {
			return b.m.get_or_add_const(b.i8_type, '${char_literal_value(node.value)}')
		}
		.string_interp {
			return b.build_string_interp(node)
		}
		.sizeof_expr {
			size := b.m.type_size(b.resolve_type(node.value))
			return b.m.get_or_add_const(b.i64_type, '${size}')
		}
		.ident {
			if node.value == 'path_separator' {
				return b.m.add_value(.string_literal, b.str_type, '/', 0)
			}
			if addr := b.vars[node.value] {
				addr_val := b.m.values[addr]
				if addr_val.kind == .argument {
					return addr
				}
				return b.emit1(.load, b.deref_type(addr), addr)
			}
			match node.value {
				'min_i8' {
					return b.m.get_or_add_const(b.i64_type, '-128')
				}
				'max_i8' {
					return b.m.get_or_add_const(b.i64_type, '127')
				}
				'min_i16' {
					return b.m.get_or_add_const(b.i64_type, '-32768')
				}
				'max_i16' {
					return b.m.get_or_add_const(b.i64_type, '32767')
				}
				'min_i32', 'min_int' {
					return b.m.get_or_add_const(b.i64_type, '-2147483648')
				}
				'max_i32', 'max_int' {
					return b.m.get_or_add_const(b.i64_type, '2147483647')
				}
				'min_i64' {
					return b.m.get_or_add_const(b.i64_type, '-9223372036854775808')
				}
				'max_i64' {
					return b.m.get_or_add_const(b.i64_type, '9223372036854775807')
				}
				'min_u8', 'min_u16', 'min_u32', 'min_u64' {
					return b.m.get_or_add_const(b.i64_type, '0')
				}
				'max_u8' {
					return b.m.get_or_add_const(b.i64_type, '255')
				}
				'max_u16' {
					return b.m.get_or_add_const(b.i64_type, '65535')
				}
				'max_u32' {
					return b.m.get_or_add_const(b.i64_type, '4294967295')
				}
				'max_u64' {
					return b.m.get_or_add_const(b.i64_type, '18446744073709551615')
				}
				else {}
			}

			return b.m.get_or_add_const(b.i64_type, '0')
		}
		.infix {
			return b.build_infix(node)
		}
		.prefix {
			return b.build_prefix(node, id)
		}
		.postfix {
			return b.build_postfix(node)
		}
		.paren {
			return b.build_expr(b.a.child(&node, 0))
		}
		.call {
			return b.build_call(id, node)
		}
		.selector {
			return b.build_selector(node)
		}
		.index {
			return b.build_index(id, node)
		}
		.struct_init {
			return b.build_struct_init(node)
		}
		.array_literal {
			return b.build_array_literal(node)
		}
		.array_init {
			return b.build_array_init(node)
		}
		.cast_expr {
			return b.build_expr(b.a.child(&node, 0))
		}
		.nil_literal {
			return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
		}
		.if_expr {
			b.build_if(node)
			return b.m.get_or_add_const(b.i64_type, '0')
		}
		.or_expr {
			return b.build_or_expr(id, node)
		}
		.block {
			return b.build_block_expr(node)
		}
		else {
			eprintln('build_expr: unsupported expr kind: ${node.kind}')
			return b.m.get_or_add_const(b.i64_type, '0')
		}
	}
}

fn char_literal_value(value string) int {
	if value.len == 0 {
		return 0
	}
	if value[0] == `\\` && value.len > 1 {
		return match value[1] {
			`n` { 10 }
			`r` { 13 }
			`t` { 9 }
			`0` { 0 }
			`\\` { 92 }
			`'` { 39 }
			else { int(value[1]) }
		}
	}
	return int(value[0])
}

fn (mut b Builder) build_block_expr(node flat.Node) ValueID {
	if node.children_count == 0 {
		return b.m.get_or_add_const(b.i64_type, '0')
	}
	for i in 0 .. node.children_count - 1 {
		b.build_stmt(b.a.child(&node, i))
	}
	last_id := b.a.child(&node, node.children_count - 1)
	last := b.a.nodes[int(last_id)]
	if last.kind == .expr_stmt && last.children_count > 0 {
		return b.build_expr(b.a.child(&last, 0))
	}
	return b.build_expr(last_id)
}

fn (mut b Builder) build_array_literal(node flat.Node) ValueID {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	mut values := []ValueID{}
	mut elem_type := b.i64_type
	for i in 0 .. node.children_count {
		value := b.build_expr(b.a.child(&node, i))
		if i == 0 {
			elem_type = b.value_type(value)
		}
		values << value
	}
	elem_size := b.m.type_size(elem_type)
	actual_elem_size := if elem_size > 0 { elem_size } else { 8 }
	elem_size_const := b.m.get_or_add_const(b.i64_type, '${actual_elem_size}')
	zero := b.m.get_or_add_const(b.i64_type, '0')
	cap_const := b.m.get_or_add_const(b.i64_type, '${node.children_count}')
	new_ref := b.m.add_value(.func_ref, b.array_type, 'array_new', b.fn_ids['array_new'])
	arr := b.emit4(.call, b.array_type, new_ref, elem_size_const, zero, cap_const)
	arr_alloca := b.emit0(.alloca, ptr_array)
	b.emit2(.store, b.void_type, arr, arr_alloca)
	push_ref := b.m.add_value(.func_ref, b.void_type, 'array_push', b.fn_ids['array_push'])
	for value in values {
		value_type := b.value_type(value)
		value_alloca := b.emit0(.alloca, b.m.type_store.get_ptr(value_type))
		b.emit2(.store, b.void_type, value, value_alloca)
		value_arg := if b.value_type(value_alloca) == ptr_i8 {
			value_alloca
		} else {
			b.emit1(.bitcast, ptr_i8, value_alloca)
		}
		b.emit3(.call, b.void_type, push_ref, arr_alloca, value_arg)
	}
	return b.emit1(.load, b.array_type, arr_alloca)
}

fn (mut b Builder) build_array_init(node flat.Node) ValueID {
	mut elem_type_name := node.value
	mut len_val := b.m.get_or_add_const(b.i64_type, '0')
	mut cap_val := b.m.get_or_add_const(b.i64_type, '0')
	if node.value.starts_with('[') {
		len_text := node.value.all_after('[').all_before(']')
		len_val = b.m.get_or_add_const(b.i64_type, if len_text.len > 0 { len_text } else { '0' })
		cap_val = len_val
		elem_type_name = node.value.all_after(']')
	} else {
		mut has_cap := false
		for i in 0 .. node.children_count {
			child_id := b.a.child(&node, i)
			child := b.a.nodes[int(child_id)]
			if child.kind == .field_init && child.children_count > 0 {
				value := b.build_expr(b.a.child(&child, 0))
				if child.value == 'len' {
					len_val = value
					if !has_cap {
						cap_val = value
					}
				} else if child.value == 'cap' {
					cap_val = value
					has_cap = true
				}
			}
		}
	}
	elem_type := b.resolve_type(elem_type_name)
	elem_size := b.m.type_size(elem_type)
	actual_elem_size := if elem_size > 0 { elem_size } else { 8 }
	elem_size_const := b.m.get_or_add_const(b.i64_type, '${actual_elem_size}')
	new_ref := b.m.add_value(.func_ref, b.array_type, 'array_new', b.fn_ids['array_new'])
	return b.emit4(.call, b.array_type, new_ref, elem_size_const, len_val, cap_val)
}

fn (mut b Builder) build_or_expr(id flat.NodeId, node flat.Node) ValueID {
	if node.children_count < 2 {
		return b.m.get_or_add_const(b.i64_type, '0')
	}
	expr_id := b.a.child(&node, 0)
	expr := b.a.nodes[int(expr_id)]
	if expr.kind == .index && expr.children_count >= 2 && expr.value != 'range' {
		if result := b.build_map_index_or_expr(id, expr, b.a.child(&node, 1)) {
			return result
		}
	}
	return b.default_value_for_type(b.or_result_type(id, node.typ))
}

fn (mut b Builder) build_map_index_or_expr(id flat.NodeId, index_node flat.Node, fallback_id flat.NodeId) ?ValueID {
	base_id := b.a.child(&index_node, 0)
	key_id := b.a.child(&index_node, 1)
	map_type_name := b.expr_type_name_for_map(base_id)
	key_type_name, val_type_name := map_type_parts(map_type_name)
	if key_type_name.len == 0 || val_type_name.len == 0 {
		return none
	}
	result_type := b.or_result_type(id, val_type_name)
	ptr_result := b.m.type_store.get_ptr(result_type)
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	result_alloca := b.emit0(.alloca, ptr_result)
	map_ptr := b.map_expr_ptr(base_id)
	key_val := b.build_expr(key_id)
	key_type := b.resolve_type(key_type_name)
	key_alloca := b.emit0(.alloca, b.m.type_store.get_ptr(key_type))
	b.emit2(.store, b.void_type, key_val, key_alloca)
	key_ptr := if b.value_type(key_alloca) == ptr_i8 {
		key_alloca
	} else {
		b.emit1(.bitcast, ptr_i8, key_alloca)
	}
	zero_ptr := b.m.get_or_add_const(ptr_i8, '0')
	get_ref := b.m.add_value(.func_ref, ptr_i8, 'map__get_check', b.fn_ids['map__get_check'])
	value_ptr := b.emit4(.call, ptr_i8, get_ref, map_ptr, key_ptr, zero_ptr)
	found := b.emit2(.ne, b.i1_type, value_ptr, zero_ptr)

	then_block := b.m.add_block(b.cur_func, 'or_map_found')
	else_block := b.m.add_block(b.cur_func, 'or_map_else')
	merge_block := b.m.add_block(b.cur_func, 'or_map_merge')
	b.emit3(.br, b.void_type, found, ValueID(then_block), ValueID(else_block))

	b.cur_block = then_block
	typed_value_ptr := if ptr_result == ptr_i8 {
		value_ptr
	} else {
		b.emit1(.bitcast, ptr_result, value_ptr)
	}
	found_value := b.emit1(.load, result_type, typed_value_ptr)
	b.emit2(.store, b.void_type, found_value, result_alloca)
	if !b.current_block_terminated() {
		b.emit1(.jmp, b.void_type, ValueID(merge_block))
	}

	b.cur_block = else_block
	fallback_value := b.build_or_fallback_value(fallback_id, result_type)
	if !b.current_block_terminated() {
		b.emit2(.store, b.void_type, fallback_value, result_alloca)
		b.emit1(.jmp, b.void_type, ValueID(merge_block))
	}

	b.cur_block = merge_block
	return b.emit1(.load, result_type, result_alloca)
}

fn (mut b Builder) map_expr_ptr(id flat.NodeId) ValueID {
	node := b.a.nodes[int(id)]
	if node.kind == .ident || node.kind == .selector {
		addr := b.build_lvalue_addr(id)
		if b.value_type(addr) == b.m.type_store.get_ptr(b.map_type) {
			return addr
		}
	}
	val := b.build_expr(id)
	alloca := b.emit0(.alloca, b.m.type_store.get_ptr(b.value_type(val)))
	b.emit2(.store, b.void_type, val, alloca)
	return alloca
}

fn (mut b Builder) build_or_fallback_value(id flat.NodeId, result_type TypeID) ValueID {
	if int(id) < 0 {
		return b.default_value_for_type(result_type)
	}
	node := b.a.nodes[int(id)]
	if node.kind != .block {
		return b.build_expr(id)
	}
	if node.children_count == 0 {
		return b.default_value_for_type(result_type)
	}
	for i in 0 .. node.children_count {
		child_id := b.a.child(&node, i)
		child := b.a.nodes[int(child_id)]
		is_last := i == node.children_count - 1
		if is_last {
			if child.kind == .expr_stmt && child.children_count > 0 {
				return b.build_expr(b.a.child(&child, 0))
			}
			if b.is_stmt_kind(child.kind) {
				b.build_stmt(child_id)
				return b.default_value_for_type(result_type)
			}
			return b.build_expr(child_id)
		}
		b.build_stmt(child_id)
		if b.current_block_terminated() {
			return b.default_value_for_type(result_type)
		}
	}
	return b.default_value_for_type(result_type)
}

fn (mut b Builder) or_result_type(id flat.NodeId, fallback_type string) TypeID {
	if b.tc != unsafe { nil } {
		if typ := b.tc.expr_type(id) {
			name := typ.name()
			if name.len > 0 && name != 'unknown' {
				return b.resolve_type(name)
			}
		}
	}
	return b.resolve_type(fallback_type)
}

fn (mut b Builder) default_value_for_type(typ TypeID) ValueID {
	if typ == b.str_type {
		return b.m.add_value(.string_literal, b.str_type, '', 0)
	}
	if typ == b.array_type {
		fn_ref := b.m.add_value(.func_ref, b.array_type, 'array_new', b.fn_ids['array_new'])
		zero := b.m.get_or_add_const(b.i64_type, '0')
		one := b.m.get_or_add_const(b.i64_type, '1')
		return b.emit4(.call, b.array_type, fn_ref, one, zero, zero)
	}
	if typ > 0 && typ < b.m.type_store.types.len && b.m.type_store.types[typ].kind == .ptr_t {
		return b.m.get_or_add_const(typ, '0')
	}
	return b.m.get_or_add_const(typ, '0')
}

fn (b &Builder) is_stmt_kind(kind flat.NodeKind) bool {
	return kind in [.expr_stmt, .decl_assign, .assign, .selector_assign, .index_assign, .return_stmt,
		.for_stmt, .for_in_stmt, .break_stmt, .continue_stmt, .if_expr, .block, .assert_stmt]
}

fn (b &Builder) current_block_terminated() bool {
	if b.cur_block < 0 || b.cur_block >= b.m.blocks.len {
		return true
	}
	blk := b.m.blocks[b.cur_block]
	return blk.instrs.len > 0 && b.is_terminator(blk.instrs.last())
}

fn (mut b Builder) build_infix(node flat.Node) ValueID {
	if node.op == .logical_and || node.op == .logical_or {
		return b.build_short_circuit(node)
	}
	if node.op == .left_shift && node.value == 'push' {
		return b.build_array_push_expr(node)
	}
	lhs := b.build_expr(b.a.child(&node, 0))
	rhs := b.build_expr(b.a.child(&node, 1))
	op := match node.op {
		.plus { OpCode.add }
		.minus { OpCode.sub }
		.mul { OpCode.mul }
		.div { OpCode.sdiv }
		.mod { OpCode.srem }
		.amp { OpCode.and_ }
		.pipe { OpCode.or_ }
		.xor { OpCode.xor }
		.left_shift { OpCode.shl }
		.right_shift { OpCode.ashr }
		.eq { OpCode.eq }
		.ne { OpCode.ne }
		.lt { OpCode.lt }
		.gt { OpCode.gt }
		.le { OpCode.le }
		.ge { OpCode.ge }
		else { OpCode.add }
	}

	result_type := b.value_type(lhs)
	return b.emit2(op, result_type, lhs, rhs)
}

fn (mut b Builder) build_array_push_expr(node flat.Node) ValueID {
	if node.children_count < 2 {
		return b.m.get_or_add_const(b.i64_type, '0')
	}
	lhs_id := b.a.child(&node, 0)
	rhs_id := b.a.child(&node, 1)
	arr_ptr := b.build_lvalue_addr(lhs_id)
	rhs_val := b.build_expr(rhs_id)
	elem_type := b.value_type(rhs_val)
	elem_ptr := b.emit0(.alloca, b.m.type_store.get_ptr(elem_type))
	b.emit2(.store, b.void_type, rhs_val, elem_ptr)
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	elem_arg := if b.value_type(elem_ptr) == ptr_i8 {
		elem_ptr
	} else {
		b.emit1(.bitcast, ptr_i8, elem_ptr)
	}
	if fn_id := b.fn_ids['array_push'] {
		fn_ref := b.m.add_value(.func_ref, b.void_type, 'array_push', fn_id)
		return b.emit3(.call, b.void_type, fn_ref, arr_ptr, elem_arg)
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) build_short_circuit(node flat.Node) ValueID {
	result_alloca := b.emit0(.alloca, b.m.type_store.get_ptr(b.i1_type))
	lhs := b.build_expr(b.a.child(&node, 0))
	b.emit2(.store, b.void_type, lhs, result_alloca)

	rhs_block := b.m.add_block(b.cur_func, 'sc_rhs')
	merge_block := b.m.add_block(b.cur_func, 'sc_merge')

	if node.op == .logical_and {
		b.emit3(.br, b.void_type, lhs, ValueID(rhs_block), ValueID(merge_block))
	} else {
		b.emit3(.br, b.void_type, lhs, ValueID(merge_block), ValueID(rhs_block))
	}

	b.cur_block = rhs_block
	rhs := b.build_expr(b.a.child(&node, 1))
	b.emit2(.store, b.void_type, rhs, result_alloca)
	b.emit1(.jmp, b.void_type, ValueID(merge_block))

	b.cur_block = merge_block
	return b.emit1(.load, b.i1_type, result_alloca)
}

fn (mut b Builder) build_prefix(node flat.Node, _id flat.NodeId) ValueID {
	child_id := b.a.child(&node, 0)
	child := b.a.nodes[int(child_id)]
	if node.op == .amp && child.kind == .struct_init {
		return b.build_heap_struct_init(child)
	}
	if node.op == .amp && child.kind == .ident {
		if addr := b.vars[child.value] {
			return addr
		}
	}
	if node.op == .amp && child.kind == .selector {
		return b.build_selector_addr(child)
	}
	if node.op == .amp && child.kind == .index {
		return b.build_index_addr(child_id, child)
	}
	val := b.build_expr(child_id)
	match node.op {
		.minus {
			zero := b.m.get_or_add_const(b.i64_type, '0')
			return b.emit2(.sub, b.value_type(val), zero, val)
		}
		.not {
			zero := b.m.get_or_add_const(b.i1_type, '0')
			return b.emit2(.eq, b.i1_type, val, zero)
		}
		.bit_not {
			minus_one := b.m.get_or_add_const(b.i64_type, '-1')
			return b.emit2(.xor, b.value_type(val), val, minus_one)
		}
		.amp {
			return val
		}
		.mul {
			return b.emit1(.load, b.deref_type(val), val)
		}
		else {
			return val
		}
	}
}

fn (mut b Builder) build_postfix(node flat.Node) ValueID {
	child_id := b.a.child(&node, 0)
	child := b.a.nodes[int(child_id)]
	if child.kind == .ident {
		if addr := b.vars[child.value] {
			cur := b.emit1(.load, b.deref_type(addr), addr)
			one := b.m.get_or_add_const(b.i64_type, '1')
			op := if node.op == .inc { OpCode.add } else { OpCode.sub }
			result := b.emit2(op, b.value_type(cur), cur, one)
			b.emit2(.store, b.void_type, result, addr)
			return cur
		}
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) build_lvalue_addr(id flat.NodeId) ValueID {
	if int(id) < 0 {
		return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.ident {
			if addr := b.vars[node.value] {
				elem_type := b.deref_type(addr)
				if elem_type > 0 && elem_type < b.m.type_store.types.len {
					elem := b.m.type_store.types[elem_type]
					if elem.kind == .ptr_t {
						return b.emit1(.load, elem_type, addr)
					}
				}
				return addr
			}
		}
		.selector {
			return b.build_selector_addr(node)
		}
		.index {
			return b.build_index_addr(id, node)
		}
		else {}
	}

	val := b.build_expr(id)
	val_type := b.value_type(val)
	tmp := b.emit0(.alloca, b.m.type_store.get_ptr(val_type))
	b.emit2(.store, b.void_type, val, tmp)
	return tmp
}

fn (mut b Builder) build_selector_addr(node flat.Node) ValueID {
	if node.children_count == 0 {
		return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
	}
	base_id := b.a.child(&node, 0)
	base := b.a.nodes[int(base_id)]
	if base.kind == .ident {
		if addr := b.vars[base.value] {
			return b.get_field_ptr(addr, node.value)
		}
	}
	if base.kind == .selector {
		base_addr := b.build_selector_addr(base)
		return b.get_field_ptr(base_addr, node.value)
	}
	base_val := b.build_expr(base_id)
	base_typ := b.value_type(base_val)
	if base_typ > 0 && base_typ < b.m.type_store.types.len
		&& b.m.type_store.types[base_typ].kind == .struct_t {
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(base_typ))
		b.emit2(.store, b.void_type, base_val, alloca)
		return b.get_field_ptr(alloca, node.value)
	}
	return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
}

fn (mut b Builder) build_call(id flat.NodeId, node flat.Node) ValueID {
	fn_node_id := b.a.child(&node, 0)
	fn_node := b.a.nodes[int(fn_node_id)]
	fn_name := fn_node.value

	mut is_method := false
	mut base_id := flat.NodeId(0)
	mut actual_name := fn_name
	if fn_node.kind == .selector {
		base_id = b.a.child(&fn_node, 0)
		base := b.a.nodes[int(base_id)]
		if base.kind == .ident && base.value == 'C' {
			actual_name = fn_node.value
		} else {
			mut found_name := fn_node.value
			mut resolved_handled := false
			if builder_name := b.builder_method_name_for_base(base, fn_node.value) {
				found_name = builder_name
				is_method = true
				resolved_handled = true
			}
			if !resolved_handled {
				if resolved := b.resolved_call_name(id) {
					found_name = resolved
					if b.resolved_selector_has_receiver(resolved, node) {
						is_method = true
					}
					resolved_handled = true
				}
			}
			if !resolved_handled && base.kind == .ident {
				full_name := '${base.value}.${fn_node.value}'
				c_name := full_name.replace('.', '__')
				if full_name in b.fn_ids {
					found_name = full_name
				} else if c_name in b.fn_ids {
					found_name = c_name
				}
			}
			if found_name == fn_node.value {
				for fname, _ in b.fn_ids {
					if fname.ends_with('.${fn_node.value}') || fname.ends_with('__${fn_node.value}') {
						found_name = fname
						is_method = true
						break
					}
				}
			}
			actual_name = found_name
		}
	} else {
		if resolved := b.resolved_call_name(id) {
			actual_name = resolved
		}
	}

	if actual_name == 'FILE' {
		if node.children_count > 1 {
			return b.build_expr(b.a.child(&node, 1))
		}
		return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
	}
	if actual_name == 'IError' {
		if node.children_count > 1 {
			return b.build_expr(b.a.child(&node, 1))
		}
		return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
	}
	if actual_name == 'join_path' || actual_name == 'os.join_path' {
		return b.build_join_path_call(node)
	}
	if fn_node.kind == .selector && node.children_count == 2 {
		base := b.a.child_node(fn_node, 0)
		if base.kind == .ident && base.value == 'C' && actual_name !in b.fn_ids {
			return b.build_expr(b.a.child(&node, 1))
		}
	}
	if node.children_count == 2 && actual_name !in b.fn_ids
		&& actual_name in ['Type', 'TypeID', 'ValueID', 'BlockID', 'NodeId'] {
		return b.build_expr(b.a.child(&node, 1))
	}
	mut resolved_name := actual_name
	if resolved_name !in b.fn_ids && resolved_name.contains('.') {
		c_name := resolved_name.replace('.', '__')
		if c_name in b.fn_ids {
			resolved_name = c_name
		} else {
			unqualified_method := resolved_name.all_after('.')
			if unqualified_method in b.fn_ids {
				resolved_name = unqualified_method
			}
		}
	}
	if resolved_name !in b.fn_ids && resolved_name.contains('__') {
		dotted_name := resolved_name.replace('__', '.')
		if dotted_name in b.fn_ids {
			resolved_name = dotted_name
		} else {
			unqualified_method := dotted_name.all_after('.')
			if unqualified_method in b.fn_ids {
				resolved_name = unqualified_method
			}
		}
	}

	mut fn_idx := 0
	if idx := b.fn_ids[resolved_name] {
		fn_idx = idx
	} else {
		cur_name := if b.cur_func >= 0 && b.cur_func < b.m.funcs.len {
			b.m.funcs[b.cur_func].name
		} else {
			'<none>'
		}
		eprintln('ssa debug: unknown function actual="${actual_name}" resolved="${resolved_name}" fn_node.kind=${fn_node.kind} fn_node.value="${fn_node.value}" in=${cur_name} call.children=${node.children_count}')
		for i in 0 .. node.children_count {
			child := b.a.child_node(&node, i)
			eprintln('  child[${i}]: kind=${child.kind} value="${child.value}" typ="${child.typ}" op=${child.op} children=${child.children_count}')
		}
		panic('ssa: unknown function `${actual_name}`')
	}
	fn_ref := b.m.add_value(.func_ref, b.void_type, resolved_name, fn_idx)
	ret_type := b.m.funcs[fn_idx].typ

	mut param_types := []TypeID{}
	if ft_id := b.fn_types[resolved_name] {
		ft := b.m.type_store.types[ft_id]
		param_types = ft.params.clone()
	}

	if resolved_name == 'map__set' {
		return b.build_map_set_call(node)
	}

	mut args := []ValueID{}
	args << fn_ref
	if is_method {
		if param_types.len > 0 {
			pt := b.m.type_store.types[param_types[0]]
			if pt.kind == .ptr_t {
				base_node := b.a.nodes[int(base_id)]
				if base_node.kind == .ident {
					if addr := b.vars[base_node.value] {
						if b.should_pass_ident_addr_for_ptr_param(addr, param_types[0]) {
							args << addr
						} else {
							args << b.build_expr(base_id)
						}
					} else {
						args << b.build_expr(base_id)
					}
				} else if base_node.kind == .selector {
					addr := b.build_selector_addr(base_node)
					if b.should_pass_ident_addr_for_ptr_param(addr, param_types[0]) {
						args << addr
					} else {
						args << b.build_expr(base_id)
					}
				} else {
					args << b.build_expr(base_id)
				}
			} else {
				args << b.build_expr(base_id)
			}
		} else {
			args << b.build_expr(base_id)
		}
	}
	for i in 1 .. node.children_count {
		arg_id := b.a.child(&node, i)
		param_idx := if is_method { i } else { i - 1 }
		if resolved_name == 'fixed_array_contains_string' && param_idx == 0 {
			if arg := b.build_const_string_array_arg(arg_id) {
				args << arg
				continue
			}
		}
		if param_idx < param_types.len {
			pt := b.m.type_store.types[param_types[param_idx]]
			if pt.kind == .ptr_t {
				arg_node := b.a.nodes[int(arg_id)]
				if arg_node.kind == .ident {
					if addr := b.vars[arg_node.value] {
						if b.should_pass_ident_addr_for_ptr_param(addr, param_types[param_idx]) {
							args << addr
							continue
						}
					}
				}
			}
		}
		args << b.build_expr(arg_id)
	}
	return b.m.add_instr(.call, b.cur_block, ret_type, args)
}

fn (mut b Builder) build_const_string_array_arg(id flat.NodeId) ?ValueID {
	if int(id) < 0 {
		return none
	}
	node := b.a.nodes[int(id)]
	if node.kind != .ident {
		return none
	}
	expr_id := b.lookup_const_expr(node.value) or { return none }
	expr := b.a.nodes[int(expr_id)]
	if expr.kind != .array_literal || expr.children_count == 0 {
		return none
	}
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	count := b.m.get_or_add_const(b.i64_type, '${expr.children_count}')
	alloca := b.emit1(.alloca, ptr_string, count)
	stride := b.m.type_size(b.str_type)
	for i in 0 .. expr.children_count {
		child_id := b.a.child(&expr, i)
		child := b.a.nodes[int(child_id)]
		if child.kind != .string_literal {
			return none
		}
		value := b.build_expr(child_id)
		off := b.m.get_or_add_const(b.i64_type, '${i * stride}')
		slot := b.emit2(.get_element_ptr, ptr_string, alloca, off)
		b.emit2(.store, b.void_type, value, slot)
	}
	return b.emit1(.bitcast, ptr_i8, alloca)
}

fn (mut b Builder) build_const_i32_array_arg(id flat.NodeId) ?ValueID {
	if int(id) < 0 {
		return none
	}
	node := b.a.nodes[int(id)]
	if node.kind != .ident {
		return none
	}
	expr_id := b.lookup_const_expr(node.value) or { return none }
	expr := b.a.nodes[int(expr_id)]
	if expr.kind != .array_literal || expr.children_count == 0 {
		return none
	}
	mut values := []string{}
	for i in 0 .. expr.children_count {
		child_id := b.a.child(&expr, i)
		value := b.const_int_literal_value(child_id) or { return none }
		values << value
	}
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	count := b.m.get_or_add_const(b.i64_type, '${values.len}')
	alloca := b.emit1(.alloca, ptr_i32, count)
	for i, value in values {
		const_val := b.m.get_or_add_const(b.i32_type, value)
		off := b.m.get_or_add_const(b.i64_type, '${i * b.m.type_size(b.i32_type)}')
		slot := b.emit2(.get_element_ptr, ptr_i32, alloca, off)
		b.emit2(.store, b.void_type, const_val, slot)
	}
	return alloca
}

fn (b &Builder) const_int_literal_value(id flat.NodeId) ?string {
	if int(id) < 0 {
		return none
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			return node.value
		}
		.paren, .cast_expr {
			if node.children_count > 0 {
				return b.const_int_literal_value(b.a.child(&node, 0))
			}
		}
		.call {
			if node.children_count == 2 {
				return b.const_int_literal_value(b.a.child(&node, 1))
			}
		}
		else {}
	}

	return none
}

fn (b &Builder) lookup_const_expr(name string) ?flat.NodeId {
	if !name.contains('.') && b.cur_module.len > 0 && b.cur_module != 'main' {
		qualified := '${b.cur_module}.${name}'
		if expr := b.const_exprs[qualified] {
			return expr
		}
	}
	if expr := b.const_exprs[name] {
		return expr
	}
	return none
}

fn (mut b Builder) build_map_set_call(node flat.Node) ValueID {
	fn_idx := b.fn_ids['v3_map_set_sized']
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_set_sized', fn_idx)
	mut args := []ValueID{}
	args << fn_ref
	for i in 1 .. node.children_count {
		args << b.build_expr(b.a.child(&node, i))
	}
	key_size, val_size := b.map_set_call_sizes(node)
	args << b.m.get_or_add_const(b.i64_type, '${key_size}')
	args << b.m.get_or_add_const(b.i64_type, '${val_size}')
	return b.m.add_instr(.call, b.cur_block, b.void_type, args)
}

fn (mut b Builder) map_set_call_sizes(node flat.Node) (int, int) {
	if node.children_count <= 1 {
		return 16, 8
	}
	map_type := b.map_arg_type_name(b.a.child(&node, 1))
	key_type, val_type := map_type_parts(map_type)
	if key_type.len == 0 || val_type.len == 0 {
		return 16, 8
	}
	key_size := b.m.type_size(b.resolve_type(key_type))
	val_size := b.m.type_size(b.resolve_type(val_type))
	actual_key_size := if key_size > 0 { key_size } else { 8 }
	actual_val_size := if val_size > 0 { val_size } else { 8 }
	return actual_key_size, actual_val_size
}

fn (b &Builder) map_arg_type_name(id flat.NodeId) string {
	if int(id) < 0 {
		return ''
	}
	node := b.a.nodes[int(id)]
	if node.kind == .prefix && node.children_count > 0 && node.op == .amp {
		return b.expr_type_name_for_map(b.a.child(&node, 0)).trim_left('&')
	}
	return b.expr_type_name_for_map(id).trim_left('&')
}

fn (b &Builder) expr_type_name_for_map(id flat.NodeId) string {
	if int(id) < 0 {
		return ''
	}
	checked := b.checked_expr_type_name(id)
	if checked.len > 0 && checked != 'unknown' {
		return checked
	}
	node := b.a.nodes[int(id)]
	if node.typ.len > 0 {
		return node.typ
	}
	if node.kind == .prefix && node.children_count > 0 && node.op == .amp {
		inner := b.expr_type_name_for_map(b.a.child(&node, 0))
		if inner.len > 0 {
			return '&' + inner
		}
	}
	if node.kind == .ident {
		return b.var_type_names[node.value] or { '' }
	}
	if node.kind == .selector && node.children_count > 0 {
		base_type := b.expr_type_name_for_map(b.a.child(&node, 0)).trim_left('&')
		field_key := base_type + '.' + node.value
		if field_type := b.struct_field_types[field_key] {
			return field_type
		}
		short_type := base_type.all_after('.')
		short_key := short_type + '.' + node.value
		if field_type := b.struct_field_types[short_key] {
			return field_type
		}
	}
	return ''
}

fn map_type_parts(map_type string) (string, string) {
	clean := map_type.trim_left('&')
	if !clean.starts_with('map[') {
		return '', ''
	}
	mut depth := 0
	for i in 4 .. clean.len {
		c := clean[i]
		if c == `[` {
			depth++
		} else if c == `]` {
			if depth == 0 {
				return clean[4..i], clean[i + 1..]
			}
			depth--
		}
	}
	return '', ''
}

fn (mut b Builder) build_join_path_call(node flat.Node) ValueID {
	if node.children_count <= 1 {
		return b.m.add_value(.string_literal, b.str_type, '', 0)
	}
	mut result := b.build_expr(b.a.child(&node, 1))
	if node.children_count == 2 {
		return result
	}
	mut fn_idx := 0
	mut found_fn := false
	if idx := b.fn_ids['join_path_single'] {
		fn_idx = idx
		found_fn = true
	}
	if !found_fn {
		if idx := b.fn_ids['os.join_path_single'] {
			fn_idx = idx
			found_fn = true
		}
	}
	if !found_fn {
		panic('ssa: unknown function `join_path_single`')
	}
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'join_path_single', fn_idx)
	for i in 2 .. node.children_count {
		arg := b.build_expr(b.a.child(&node, i))
		mut args := []ValueID{}
		args << fn_ref
		args << result
		args << arg
		result = b.m.add_instr(.call, b.cur_block, b.str_type, args)
	}
	return result
}

fn (b &Builder) declared_v_type_name(lhs_id flat.NodeId, rhs_id flat.NodeId) string {
	if int(rhs_id) >= 0 {
		rhs := b.a.nodes[int(rhs_id)]
		if rhs.kind == .call && rhs.children_count > 0 {
			fn_node := b.a.child_node(&rhs, 0)
			if fn_node.kind == .selector && fn_node.children_count > 0
				&& fn_node.value == 'new_builder' {
				base := b.a.child_node(fn_node, 0)
				if base.kind == .ident && base.value == 'strings' {
					return 'strings.Builder'
				}
			}
		}
	}
	lhs_type := b.checked_expr_type_name(lhs_id)
	if lhs_type.len > 0 && lhs_type != 'unknown' {
		return lhs_type
	}
	rhs_type := b.checked_expr_type_name(rhs_id)
	if rhs_type.len > 0 && rhs_type != 'unknown' {
		return rhs_type
	}
	return ''
}

fn (b &Builder) checked_expr_type_name(id flat.NodeId) string {
	if b.tc == unsafe { nil } || int(id) < 0 {
		return ''
	}
	if typ := b.tc.expr_type(id) {
		return typ.name()
	}
	if typ := b.tc.expr_types[int(id)] {
		return typ.name()
	}
	return ''
}

fn (b &Builder) builder_method_name_for_base(base flat.Node, method string) ?string {
	if base.kind != .ident {
		return none
	}
	if !is_builder_method(method) {
		return none
	}
	mut receiver_type := b.var_type_names[base.value] or { '' }
	if receiver_type.starts_with('&') {
		receiver_type = receiver_type[1..]
	}
	if receiver_type != 'strings.Builder' && receiver_type != 'Builder' {
		return none
	}
	name := 'strings.Builder.${method}'
	if name in b.fn_ids {
		return name
	}
	return none
}

fn is_builder_method(method string) bool {
	return method in ['write_string', 'writeln', 'str', 'free', 'write_u8', 'write_ptr',
		'write_runes', 'last_n']
}

fn (b &Builder) resolved_call_name(id flat.NodeId) ?string {
	if b.tc == unsafe { nil } {
		return none
	}
	if name := b.tc.resolved_calls[int(id)] {
		if name.len > 0 {
			return name
		}
	}
	return none
}

fn (b &Builder) resolved_selector_has_receiver(resolved string, node flat.Node) bool {
	explicit_arg_count := node.children_count - 1
	if has_receiver := b.fn_signature_has_receiver(resolved, explicit_arg_count) {
		return has_receiver
	}
	if resolved.contains('.') {
		c_name := resolved.replace('.', '__')
		if has_receiver := b.fn_signature_has_receiver(c_name, explicit_arg_count) {
			return has_receiver
		}
		unqualified := resolved.all_after('.')
		if has_receiver := b.fn_signature_has_receiver(unqualified, explicit_arg_count) {
			return has_receiver
		}
	}
	if resolved.contains('__') {
		dotted := resolved.replace('__', '.')
		if has_receiver := b.fn_signature_has_receiver(dotted, explicit_arg_count) {
			return has_receiver
		}
		unqualified := dotted.all_after('.')
		if has_receiver := b.fn_signature_has_receiver(unqualified, explicit_arg_count) {
			return has_receiver
		}
	}
	return true
}

fn (b &Builder) fn_signature_has_receiver(name string, explicit_arg_count int) ?bool {
	if ft_id := b.fn_types[name] {
		ft := b.m.type_store.types[ft_id]
		if ft.params.len == explicit_arg_count {
			return false
		}
		if ft.params.len < explicit_arg_count {
			return false
		}
		if ft.params.len == explicit_arg_count + 1 {
			return true
		}
	}
	return none
}

fn (b &Builder) should_pass_ident_addr_for_ptr_param(addr ValueID, param_type TypeID) bool {
	if param_type <= 0 || param_type >= b.m.type_store.types.len {
		return false
	}
	param := b.m.type_store.types[param_type]
	if param.kind != .ptr_t {
		return false
	}
	arg_type := b.deref_type(addr)
	if arg_type <= 0 || arg_type >= b.m.type_store.types.len {
		return true
	}
	arg := b.m.type_store.types[arg_type]
	return arg.kind != .ptr_t
}

fn (mut b Builder) build_selector(node flat.Node) ValueID {
	base_id := b.a.child(&node, 0)
	base := b.a.nodes[int(base_id)]
	field_name := node.value

	if base.kind == .ident && base.value == 'os' {
		if field_name == 'args' {
			if fn_id := b.fn_ids['arguments'] {
				fn_ref := b.m.add_value(.func_ref, b.array_type, 'arguments', fn_id)
				return b.emit1(.call, b.array_type, fn_ref)
			}
		}
		if field_name == 'path_separator' {
			return b.m.add_value(.string_literal, b.str_type, '/', 0)
		}
	}

	if base.kind == .ident {
		if addr := b.vars[base.value] {
			field_ptr := b.get_field_ptr(addr, field_name)
			return b.emit1(.load, b.deref_type(field_ptr), field_ptr)
		}
	}
	if base.kind == .selector && b.selector_has_addressable_root(&base) {
		field_ptr := b.build_selector_addr(node)
		return b.emit1(.load, b.deref_type(field_ptr), field_ptr)
	}
	base_val := b.build_expr(base_id)
	base_typ := b.value_type(base_val)
	if base_typ > 0 && base_typ < b.m.type_store.types.len {
		base_type := b.m.type_store.types[base_typ]
		if base_type.kind == .ptr_t && base_type.elem_type > 0
			&& base_type.elem_type < b.m.type_store.types.len
			&& b.m.type_store.types[base_type.elem_type].kind == .struct_t {
			field_ptr := b.get_field_ptr(base_val, field_name)
			return b.emit1(.load, b.deref_type(field_ptr), field_ptr)
		}
	}
	if base_typ > 0 && base_typ < b.m.type_store.types.len
		&& b.m.type_store.types[base_typ].kind == .struct_t {
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(base_typ))
		b.emit2(.store, b.void_type, base_val, alloca)
		field_ptr := b.get_field_ptr(alloca, field_name)
		return b.emit1(.load, b.deref_type(field_ptr), field_ptr)
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (b &Builder) selector_has_addressable_root(node &flat.Node) bool {
	match node.kind {
		.ident {
			if _ := b.vars[node.value] {
				return true
			}
		}
		.selector {
			if node.children_count > 0 {
				return b.selector_has_addressable_root(b.a.child_node(node, 0))
			}
		}
		else {}
	}

	return false
}

fn (mut b Builder) build_index(id flat.NodeId, node flat.Node) ValueID {
	base_id := b.a.child(&node, 0)
	if node.children_count >= 2 {
		if base := b.build_const_i32_array_arg(base_id) {
			index := b.build_expr(b.a.child(&node, 1))
			elem_size := b.m.get_or_add_const(b.i64_type, '${b.m.type_size(b.i32_type)}')
			offset := b.emit2(.mul, b.i64_type, index, elem_size)
			elem_ptr := b.emit2(.add, b.m.type_store.get_ptr(b.i32_type), base, offset)
			return b.emit1(.load, b.i32_type, elem_ptr)
		}
	}
	base := b.build_expr(base_id)
	if node.value == 'range' {
		start := if node.children_count > 1 {
			start_node := b.a.child_node(&node, 1)
			if start_node.kind == .empty {
				b.m.get_or_add_const(b.i64_type, '0')
			} else {
				b.build_expr(b.a.child(&node, 1))
			}
		} else {
			b.m.get_or_add_const(b.i64_type, '0')
		}
		end := if node.children_count > 2 {
			end_node := b.a.child_node(&node, 2)
			if end_node.kind == .empty {
				b.load_struct_field_from_value(base, b.array_type, 'len')
			} else {
				b.build_expr(b.a.child(&node, 2))
			}
		} else {
			b.load_struct_field_from_value(base, b.array_type, 'len')
		}
		fn_ref := b.m.add_value(.func_ref, b.array_type, 'array_slice', b.fn_ids['array_slice'])
		return b.emit4(.call, b.array_type, fn_ref, base, start, end)
	}
	if node.children_count < 2 {
		return b.m.get_or_add_const(b.i64_type, '0')
	}
	index := b.build_expr(b.a.child(&node, 1))
	base_typ := b.value_type(base)
	if base_typ == b.str_type {
		data := b.load_struct_field_from_value(base, b.str_type, 'str')
		elem_ptr := b.emit2(.add, b.m.type_store.get_ptr(b.i8_type), data, index)
		return b.emit1(.load, b.i8_type, elem_ptr)
	}
	if base_typ > 0 && base_typ < b.m.type_store.types.len {
		base_type := b.m.type_store.types[base_typ]
		if base_type.kind == .ptr_t {
			elem_type := if base_type.elem_type > 0 { base_type.elem_type } else { b.i8_type }
			elem_size := b.m.type_size(elem_type)
			offset := if elem_size > 1 {
				elem_size_const := b.m.get_or_add_const(b.i64_type, '${elem_size}')
				b.emit2(.mul, b.i64_type, index, elem_size_const)
			} else {
				index
			}
			elem_ptr := b.emit2(.add, base_typ, base, offset)
			return b.emit1(.load, elem_type, elem_ptr)
		}
	}
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	fn_ref := b.m.add_value(.func_ref, ptr_i8, 'array_get', b.fn_ids['array_get'])
	elem_ptr := b.emit3(.call, ptr_i8, fn_ref, base, index)
	elem_type := b.index_elem_type(id, node)
	typed_ptr := b.emit1(.bitcast, b.m.type_store.get_ptr(elem_type), elem_ptr)
	return b.emit1(.load, elem_type, typed_ptr)
}

fn (mut b Builder) build_index_addr(id flat.NodeId, node flat.Node) ValueID {
	if node.children_count < 2 {
		return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
	}
	base_id := b.a.child(&node, 0)
	if base := b.build_const_i32_array_arg(base_id) {
		index := b.build_expr(b.a.child(&node, 1))
		elem_size := b.m.get_or_add_const(b.i64_type, '${b.m.type_size(b.i32_type)}')
		offset := b.emit2(.mul, b.i64_type, index, elem_size)
		return b.emit2(.add, b.m.type_store.get_ptr(b.i32_type), base, offset)
	}
	base := b.build_expr(base_id)
	index := b.build_expr(b.a.child(&node, 1))
	base_typ := b.value_type(base)
	if base_typ == b.str_type {
		data := b.load_struct_field_from_value(base, b.str_type, 'str')
		return b.emit2(.add, b.m.type_store.get_ptr(b.i8_type), data, index)
	}
	if base_typ > 0 && base_typ < b.m.type_store.types.len {
		base_type := b.m.type_store.types[base_typ]
		if base_type.kind == .ptr_t {
			elem_type := if base_type.elem_type > 0 { base_type.elem_type } else { b.i8_type }
			elem_size := b.m.type_size(elem_type)
			offset := if elem_size > 1 {
				elem_size_const := b.m.get_or_add_const(b.i64_type, '${elem_size}')
				b.emit2(.mul, b.i64_type, index, elem_size_const)
			} else {
				index
			}
			return b.emit2(.add, base_typ, base, offset)
		}
	}
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	fn_ref := b.m.add_value(.func_ref, ptr_i8, 'array_get', b.fn_ids['array_get'])
	elem_ptr := b.emit3(.call, ptr_i8, fn_ref, base, index)
	elem_type := b.index_elem_type(id, node)
	return b.emit1(.bitcast, b.m.type_store.get_ptr(elem_type), elem_ptr)
}

fn (mut b Builder) load_struct_field_from_value(value ValueID, typ TypeID, field_name string) ValueID {
	alloca := b.emit0(.alloca, b.m.type_store.get_ptr(typ))
	b.emit2(.store, b.void_type, value, alloca)
	field_ptr := b.get_field_ptr(alloca, field_name)
	field := b.emit1(.load, b.deref_type(field_ptr), field_ptr)
	if typ == b.array_type && field_name in ['offset', 'len', 'cap', 'flags', 'element_size'] {
		return b.emit1(.zext, b.i64_type, field)
	}
	return field
}

fn (mut b Builder) index_elem_type(id flat.NodeId, node flat.Node) TypeID {
	if b.tc != unsafe { nil } {
		if typ := b.tc.expr_types[int(id)] {
			name := typ.name()
			if name != '' && !name.starts_with('[]') && name != 'unknown' {
				return b.resolve_type(name)
			}
		}
	}
	if node.typ != '' && !node.typ.starts_with('[]') {
		return b.resolve_type(node.typ)
	}
	return b.i64_type
}

fn (mut b Builder) build_struct_init(node flat.Node) ValueID {
	typ_id, struct_name := b.struct_literal_type(node.value)
	if typ_id > 0 {
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(typ_id))
		typ := b.m.type_store.types[typ_id]
		mut initialized := map[string]bool{}
		for i in 0 .. node.children_count {
			field_node := b.a.child_node(&node, i)
			field_val := b.build_expr(b.a.child(field_node, 0))
			for fi, fname in typ.field_names {
				if fname == field_node.value {
					offset := b.m.struct_field_offset(typ_id, fi)
					off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
					field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
					field_ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(field_type),
						alloca, off_const)
					b.emit2(.store, b.void_type, field_val, field_ptr)
					initialized[fname] = true
					break
				}
			}
		}
		zero := b.m.get_or_add_const(b.i64_type, '0')
		for fi, fname in typ.field_names {
			if fname !in initialized {
				offset := b.m.struct_field_offset(typ_id, fi)
				off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
				field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
				field_ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(field_type), alloca,
					off_const)
				default_value := b.default_field_value(struct_name, fname, zero)
				b.emit2(.store, b.void_type, default_value, field_ptr)
			}
		}
		return b.emit1(.load, typ_id, alloca)
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) default_field_value(struct_name string, field_name string, zero ValueID) ValueID {
	field_type := b.field_type_name(struct_name, field_name)
	if field_type.starts_with('[]') {
		elem_name := field_type[2..]
		elem_type := b.resolve_type(elem_name)
		elem_size := b.m.type_size(elem_type)
		elem_size_const := b.m.get_or_add_const(b.i64_type, '${elem_size}')
		if fn_id := b.fn_ids['array_new'] {
			fn_ref := b.m.add_value(.func_ref, b.void_type, 'array_new', fn_id)
			return b.emit4(.call, b.array_type, fn_ref, elem_size_const, zero, zero)
		}
	}
	if field_type.starts_with('map[') {
		key_type, val_type := map_type_parts(field_type)
		key_size := b.m.type_size(b.resolve_type(key_type))
		val_size := b.m.type_size(b.resolve_type(val_type))
		actual_key_size := if key_size > 0 { key_size } else { 8 }
		actual_val_size := if val_size > 0 { val_size } else { 8 }
		key_size_const := b.m.get_or_add_const(b.i64_type, '${actual_key_size}')
		val_size_const := b.m.get_or_add_const(b.i64_type, '${actual_val_size}')
		if fn_id := b.fn_ids['new_map'] {
			fn_ref := b.m.add_value(.func_ref, b.void_type, 'new_map', fn_id)
			mut args := []ValueID{}
			args << fn_ref
			args << key_size_const
			args << val_size_const
			args << zero
			args << zero
			args << zero
			args << zero
			return b.m.add_instr(.call, b.cur_block, b.map_type, args)
		}
	}
	return zero
}

fn (b &Builder) field_type_name(struct_name string, field_name string) string {
	key := struct_name + '.' + field_name
	if typ := b.struct_field_types[key] {
		return typ
	}
	short_name := struct_name.all_after('.')
	short_key := short_name + '.' + field_name
	if typ := b.struct_field_types[short_key] {
		return typ
	}
	return ''
}

fn (b &Builder) struct_literal_type(name string) (TypeID, string) {
	short_name := name.all_after('.')
	if !name.contains('.') && b.cur_module.len > 0 && b.cur_module != 'main'
		&& b.cur_module != 'builtin' {
		qualified_name := b.cur_module + '.' + short_name
		if typ := b.struct_types[qualified_name] {
			return typ, qualified_name
		}
	}
	if typ := b.struct_types[name] {
		return typ, name
	}
	if typ := b.struct_types[short_name] {
		return typ, short_name
	}
	return TypeID(0), name
}

fn (mut b Builder) build_heap_struct_init(node flat.Node) ValueID {
	typ_id, struct_name := b.struct_literal_type(node.value)
	if typ_id > 0 {
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(typ_id))
		typ := b.m.type_store.types[typ_id]
		mut initialized := map[string]bool{}
		for i in 0 .. node.children_count {
			field_node := b.a.child_node(&node, i)
			field_val := b.build_expr(b.a.child(field_node, 0))
			for fi, fname in typ.field_names {
				if fname == field_node.value {
					offset := b.m.struct_field_offset(typ_id, fi)
					off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
					field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
					field_ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(field_type),
						alloca, off_const)
					b.emit2(.store, b.void_type, field_val, field_ptr)
					initialized[fname] = true
					break
				}
			}
		}
		zero := b.m.get_or_add_const(b.i64_type, '0')
		for fi, fname in typ.field_names {
			if fname !in initialized {
				offset := b.m.struct_field_offset(typ_id, fi)
				off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
				field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
				field_ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(field_type), alloca,
					off_const)
				default_value := b.default_field_value(struct_name, fname, zero)
				b.emit2(.store, b.void_type, default_value, field_ptr)
			}
		}
		size := b.m.type_size(typ_id)
		size_const := b.m.get_or_add_const(b.i64_type, '${size}')
		ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
		src_cast := b.emit1(.bitcast, ptr_i8, alloca)
		memdup_ref := b.m.add_value(.func_ref, ptr_i8, 'memdup', b.fn_ids['memdup'])
		result := b.emit3(.call, ptr_i8, memdup_ref, src_cast, size_const)
		return b.emit1(.bitcast, b.m.type_store.get_ptr(typ_id), result)
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) build_string_interp(node flat.Node) ValueID {
	n := node.children_count
	if n == 0 {
		return b.m.add_value(.string_literal, b.str_type, '', 0)
	}
	mut parts := []ValueID{}
	for i in 0 .. n {
		child_id := b.a.child(&node, i)
		child := b.a.nodes[int(child_id)]
		if child.kind == .string_literal {
			parts << b.m.add_value(.string_literal, b.str_type, child.value, 0)
		} else {
			vtype := b.infer_v_type(child_id)
			if vtype == 'string' {
				parts << b.build_expr(child_id)
			} else {
				val := b.build_expr(child_id)
				int_str_ref := b.m.add_value(.func_ref, b.str_type, 'int_str', b.fn_ids['int_str'])
				parts << b.emit2(.call, b.str_type, int_str_ref, val)
			}
		}
	}
	count_const := b.m.get_or_add_const(b.i64_type, '${parts.len}')
	alloca := b.emit1(.alloca, b.m.type_store.get_ptr(b.str_type), count_const)
	for i, part in parts {
		off_const := b.m.get_or_add_const(b.i64_type, '${i * b.m.type_size(b.str_type)}')
		ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(b.str_type), alloca, off_const)
		b.emit2(.store, b.void_type, part, ptr)
	}
	fn_ref := b.m.add_value(.func_ref, b.str_type, 'string_plus_many', b.fn_ids['string_plus_many'])
	return b.emit3(.call, b.str_type, fn_ref, count_const, alloca)
}

fn (mut b Builder) get_field_ptr(base_addr ValueID, field_name string) ValueID {
	mut struct_typ_id := TypeID(0)
	base_val := b.m.values[base_addr]
	base_type_id := base_val.typ
	if base_type_id > 0 && base_type_id < b.m.type_store.types.len {
		base_type := b.m.type_store.types[base_type_id]
		if base_type.kind == .ptr_t {
			elem_type := b.m.type_store.types[base_type.elem_type]
			if elem_type.kind == .ptr_t {
				struct_typ_id = elem_type.elem_type
			} else if elem_type.kind == .struct_t {
				struct_typ_id = base_type.elem_type
			}
		}
	}

	if struct_typ_id > 0 {
		typ := b.m.type_store.types[struct_typ_id]
		for fi, fname in typ.field_names {
			if fname == field_name {
				offset := b.m.struct_field_offset(struct_typ_id, fi)
				off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
				field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
				ptr_type := b.m.type_store.get_ptr(field_type)

				if b.m.type_store.types[b.m.values[base_addr].typ].kind == .ptr_t {
					inner := b.m.type_store.types[b.m.values[base_addr].typ]
					if inner.kind == .ptr_t && b.m.type_store.types[inner.elem_type].kind == .ptr_t {
						loaded := b.emit1(.load, inner.elem_type, base_addr)
						return b.emit2(.get_element_ptr, ptr_type, loaded, off_const)
					}
				}
				return b.emit2(.get_element_ptr, ptr_type, base_addr, off_const)
			}
		}
	}

	off_const := b.m.get_or_add_const(b.i64_type, '0')
	ptr_type := b.m.type_store.get_ptr(b.i64_type)
	return b.emit2(.get_element_ptr, ptr_type, base_addr, off_const)
}

fn (mut b Builder) resolve_type(name string) TypeID {
	if name.starts_with('&') {
		inner := b.resolve_type(name[1..])
		return b.m.type_store.get_ptr(inner)
	}
	if alias := b.type_alias_target(name) {
		if alias != name {
			return b.resolve_type(alias)
		}
	}
	if name.starts_with('[]') || name == 'array' || name == 'Array' {
		return b.array_type
	}
	if name == 'strings.Builder' {
		return b.array_type
	}
	if name.starts_with('map[') || name == 'map' || name == 'Map' {
		return b.map_type
	}
	return match name {
		'int' {
			b.i32_type
		}
		'i8' {
			b.i8_type
		}
		'i16' {
			b.i32_type
		}
		'i32' {
			b.i32_type
		}
		'i64' {
			b.i64_type
		}
		'u8', 'byte' {
			b.i8_type
		}
		'u16' {
			b.i32_type
		}
		'u32' {
			b.i32_type
		}
		'u64' {
			b.i64_type
		}
		'f32' {
			b.i64_type
		}
		'f64' {
			b.i64_type
		}
		'bool' {
			b.i1_type
		}
		'string' {
			b.str_type
		}
		'void', '' {
			b.void_type
		}
		'voidptr' {
			b.m.type_store.get_ptr(b.i8_type)
		}
		else {
			short_name := name.all_after('.')
			if !name.contains('.') && b.cur_module.len > 0 && b.cur_module != 'main'
				&& b.cur_module != 'builtin' {
				qualified_name := b.cur_module + '.' + short_name
				if typ := b.struct_types[qualified_name] {
					return typ
				}
			}
			if typ := b.struct_types[name] {
				return typ
			}
			if typ := b.struct_types[short_name] {
				return typ
			}
			if name == 'Builder' {
				return b.array_type
			}
			b.i64_type
		}
	}
}

fn (mut b Builder) resolve_type_in_module(name string, module_name string) TypeID {
	if name.starts_with('&') {
		inner := b.resolve_type_in_module(name[1..], module_name)
		return b.m.type_store.get_ptr(inner)
	}
	if !name.contains('.') && module_name.len > 0 && module_name != 'main'
		&& module_name != 'builtin' {
		qualified_name := module_name + '.' + name
		if typ := b.struct_types[qualified_name] {
			return typ
		}
		if alias := b.type_alias_target(qualified_name) {
			if alias != qualified_name {
				return b.resolve_type_in_module(alias, module_name)
			}
		}
	}
	return b.resolve_type(name)
}

fn (b &Builder) type_alias_target(name string) ?string {
	if b.tc == unsafe { nil } || name.len == 0 {
		return none
	}
	if target := b.tc.type_aliases[name] {
		return target
	}
	if !name.contains('.') && b.cur_module.len > 0 && b.cur_module != 'main'
		&& b.cur_module != 'builtin' {
		qualified_name := b.cur_module + '.' + name
		if target := b.tc.type_aliases[qualified_name] {
			return target
		}
	}
	return none
}

fn (b &Builder) value_type(val_id ValueID) TypeID {
	if val_id <= 0 || val_id >= b.m.values.len {
		return b.i64_type
	}
	v := b.m.values[val_id]
	if v.typ > 0 {
		return v.typ
	}
	return b.i64_type
}

fn (b &Builder) deref_type(ptr_val ValueID) TypeID {
	if ptr_val <= 0 || ptr_val >= b.m.values.len {
		return b.i64_type
	}
	v := b.m.values[ptr_val]
	if v.kind == .instruction {
		instr := b.m.instrs[v.index]
		if instr.op == .alloca || instr.op == .get_element_ptr {
			if v.typ > 0 && v.typ < b.m.type_store.types.len {
				t := b.m.type_store.types[v.typ]
				if t.kind == .ptr_t {
					return t.elem_type
				}
			}
		}
	}
	if v.kind == .global {
		if v.typ > 0 && v.typ < b.m.type_store.types.len {
			t := b.m.type_store.types[v.typ]
			if t.kind == .ptr_t {
				return t.elem_type
			}
		}
	}
	return b.i64_type
}

fn (b &Builder) infer_v_type(id flat.NodeId) string {
	if int(id) < 0 {
		return 'int'
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.string_literal, .string_interp {
			return 'string'
		}
		.int_literal {
			return 'int'
		}
		.bool_literal {
			return 'bool'
		}
		.ident {
			if addr := b.vars[node.value] {
				val := b.m.values[addr]
				if val.typ == b.str_type || (val.typ > 0 && val.typ < b.m.type_store.types.len
					&& b.m.type_store.types[val.typ].kind == .ptr_t
					&& b.m.type_store.types[val.typ].elem_type == b.str_type) {
					return 'string'
				}
			}
			return 'int'
		}
		.call {
			fn_node := b.a.child_node(&node, 0)
			if fn_node.value == 'int_str' {
				return 'string'
			}
			if fn_idx := b.fn_ids[fn_node.value] {
				ret := b.m.funcs[fn_idx].typ
				if ret == b.str_type {
					return 'string'
				}
			}
			return 'int'
		}
		.infix {
			lt := b.infer_v_type(b.a.child(&node, 0))
			if lt == 'string' {
				return 'string'
			}
			return lt
		}
		else {
			return 'int'
		}
	}
}

fn (mut b Builder) emit0(op OpCode, typ TypeID) ValueID {
	return b.m.add_instr(op, b.cur_block, typ, []ValueID{})
}

fn (mut b Builder) emit1(op OpCode, typ TypeID, a ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	return b.m.add_instr(op, b.cur_block, typ, ops)
}

fn (mut b Builder) emit2(op OpCode, typ TypeID, a ValueID, c ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	return b.m.add_instr(op, b.cur_block, typ, ops)
}

fn (mut b Builder) emit3(op OpCode, typ TypeID, a ValueID, c ValueID, d ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	ops << d
	return b.m.add_instr(op, b.cur_block, typ, ops)
}

fn (mut b Builder) emit4(op OpCode, typ TypeID, a ValueID, c ValueID, d ValueID, e ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	ops << d
	ops << e
	return b.m.add_instr(op, b.cur_block, typ, ops)
}

fn (b &Builder) compound_to_op(op flat.Op) OpCode {
	return match op {
		.plus_assign { .add }
		.minus_assign { .sub }
		.mul_assign { .mul }
		.div_assign { .sdiv }
		.mod_assign { .srem }
		.amp_assign { .and_ }
		.pipe_assign { .or_ }
		.xor_assign { .xor }
		.left_shift_assign { .shl }
		.right_shift_assign { .ashr }
		else { .add }
	}
}
