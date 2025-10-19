@[translated]
module main

struct Conn {
	fd        int
	read_buf  [4096]i8
	read_len  usize
	write_buf &i8
	write_len usize
	write_pos usize
}

struct Task {
	c    &Conn
	next &Task
}

struct Done {
	c    &Conn
	resp &i8
	len  usize
	next &Done
}

@[weak]
__global task_mutex = Pthread_mutex_t{850045863, [0]!}

@[weak]
__global task_cond = Pthread_cond_t{1018212795, [0]!}

@[weak]
__global task_head = &Task((unsafe { nil }))

@[weak]
__global task_tail = &Task((unsafe { nil }))

@[weak]
__global done_mutex = Pthread_mutex_t{850045863, [0]!}

@[weak]
__global done_head = &Done((unsafe { nil }))

@[weak]
__global done_tail = &Done((unsafe { nil }))

@[weak]
__global quit = bool(0)

@[weak]
__global wake_pipe [2]int

fn close_conn(c &Conn) {
	if c.write_buf {
		C.free(c.write_buf)
	}
	C.close(c.fd)
	C.free(c)
}

fn worker_func(arg voidptr) voidptr {
	for 1 {
		pthread_mutex_lock(&task_mutex)
		for task_head == (unsafe { nil }) && !quit {
			pthread_cond_wait(&task_cond, &task_mutex)
		}
		if quit && task_head == (unsafe { nil }) {
			pthread_mutex_unlock(&task_mutex)
			break
		}
		t := task_head
		task_head = t.next
		if task_head == (unsafe { nil }) {
			task_tail = (unsafe { nil })
		}
		pthread_mutex_unlock(&task_mutex)
		// Process sleep
		sleep(5)
		// Prepare response
		resp := C.malloc(4096)
		len := __builtin___snprintf_chk(resp, 4096, 0, __builtin_object_size(resp, if 2 > 1 {
			1
		} else {
			0
		}), c'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s',
			18, c'<b>hello world</b>')
		// Enqueue done
		d := C.malloc(sizeof(Done))
		d.c = t.c
		d.resp = resp
		d.len = len
		d.next = (unsafe { nil })
		pthread_mutex_lock(&done_mutex)
		if done_tail {
			done_tail.next = d
		} else {
			done_head = d
		}
		done_tail = d
		pthread_mutex_unlock(&done_mutex)
		// Wake IO thread
		x := `x`
		C.write(wake_pipe[1], &x, 1)
		C.free(t)
	}
	return unsafe { nil }
}

@[c: '__builtin___snprintf_chk']
@[c2v_variadic]
fn builtin___snprintf_chk(arg0 &i8, arg1 u32, arg2 int, arg3 u32, arg4 ...&i8) int

@[c: '__builtin_object_size']
fn builtin_object_size(arg0 voidptr, arg1 int) u32

fn process_dones(kq int) {
	pthread_mutex_lock(&done_mutex)
	local_head := done_head
	done_head = (unsafe { nil })
	done_tail = (unsafe { nil })
	pthread_mutex_unlock(&done_mutex)
	for local_head {
		d := local_head
		local_head = d.next
		c := d.c
		c.write_buf = d.resp
		c.write_len = d.len
		c.write_pos = 0
		// Try to write immediately
		w := C.write(c.fd, c.write_buf + c.write_pos, c.write_len - c.write_pos)
		if w > 0 {
			c.write_pos += usize(w)
		} else if w < 0 && (*__error()) != 35 && (*__error()) != 35 {
			close_conn(c)
			C.free(d)
			continue
		}
		if c.write_pos < c.write_len {
			// Add write event
			ev := Kevent{}
			for {
				__kevp__ := (&ev)
				__kevp__.ident = (c.fd)
				__kevp__.filter = (-2)
				__kevp__.flags = (1 | 32768)
				__kevp__.fflags = (0)
				__kevp__.data = (0)
				__kevp__.udata = c
				// while()
				if !(0) {
					break
				}
			}
			kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
		} else {
			C.free(c.write_buf)
			c.write_buf = (unsafe { nil })
			// Add back read event
			ev := Kevent{}
			for {
				__kevp__ := (&ev)
				__kevp__.ident = (c.fd)
				__kevp__.filter = (-1)
				__kevp__.flags = (1 | 32768)
				__kevp__.fflags = (0)
				__kevp__.data = (0)
				__kevp__.udata = c
				// while()
				if !(0) {
					break
				}
			}
			kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
			c.read_len = 0
		}
		C.free(d)
	}
}

fn main() {
	// Create server socket
	server_fd := socket(2, 1, 0)
	if server_fd < 0 {
		C.perror(c'socket')
		return
	}
	opt := 1
	setsockopt(server_fd, 65535, 4, &opt, sizeof(opt))
	addr := Sockaddr_in{}
	C.memset(&addr, 0, sizeof(addr))
	addr.sin_family = 2
	addr.sin_addr.s_addr = U_int32_t(0)
	addr.sin_port = (uint16_t((if __builtin_constant_p(8092) {
		(uint16_t((((uint16_t((8092)) & 65280) >> 8) | ((uint16_t((8092)) & 255) << 8))))
	} else {
		_oss_wap_int16(8092)
	})))
	if bind(server_fd, &Sockaddr(&addr), sizeof(addr)) < 0 {
		C.perror(c'bind')
		return
	}
	if listen(server_fd, 128) < 0 {
		C.perror(c'listen')
		return
	}
	fcntl(server_fd, 4, 4)
	// Create kqueue
	kq := kqueue()
	if kq < 0 {
		C.perror(c'kqueue')
		return
	}
	ev := Kevent{}
	for {
		__kevp__ := (&ev)
		__kevp__.ident = server_fd
		__kevp__.filter = (-1)
		__kevp__.flags = (1)
		__kevp__.fflags = (0)
		__kevp__.data = (0)
		__kevp__.udata = (unsafe { nil })
		// while()
		if !(0) {
			break
		}
	}
	kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
	// Create wake pipe
	if pipe(wake_pipe) < 0 {
		C.perror(c'pipe')
		return
	}
	fcntl(wake_pipe[0], 4, 4)
	fcntl(wake_pipe[1], 4, 4)
	for {
		__kevp__ := (&ev)
		__kevp__.ident = (wake_pipe[0])
		__kevp__.filter = (-1)
		__kevp__.flags = (1)
		__kevp__.fflags = (0)
		__kevp__.data = (0)
		__kevp__.udata = (unsafe { nil })
		// while()
		if !(0) {
			break
		}
	}
	kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
	// Create worker threads
	threads := [8]Pthread_t{}
	for i := 0; i < 8; i++ {
		pthread_create(&threads[i], (unsafe { nil }), worker_func, (unsafe { nil }))
	}
	// Event loop
	events := [64]Kevent{}
	for 1 {
		nev := kevent(kq, (unsafe { nil }), 0, events, 64, (unsafe { nil }))
		if nev < 0 {
			C.perror(c'kevent')
			break
		}
		for i := 0; i < nev; i++ {
			c := events[i].udata
			if events[i].flags & 16384 {
				if c {
					close_conn(c)
				}
				continue
			}
			if events[i].ident == C.uintptr_t(server_fd) && events[i].filter == (-1) {
				// Accept new connection
				client_fd := accept(server_fd, (unsafe { nil }), (unsafe { nil }))
				if client_fd < 0 {
					continue
				}
				new_c := C.malloc(sizeof(Conn))
				C.memset(new_c, 0, sizeof(Conn))
				new_c.fd = client_fd
				fcntl(new_c.fd, 4, 4)
				for {
					__kevp__ := (&ev)
					__kevp__.ident = (new_c.fd)
					__kevp__.filter = (-1)
					__kevp__.flags = (1 | 32768)
					__kevp__.fflags = (0)
					__kevp__.data = (0)
					__kevp__.udata = new_c
					// while()
					if !(0) {
						break
					}
				}
				kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
			} else if events[i].ident == C.uintptr_t(wake_pipe[0]) && events[i].filter == (-1) {
				// Drain pipe
				buf := [1024]i8{}
				for C.read(wake_pipe[0], buf, sizeof(buf)) > 0 {
					0
				}
				// Process completed tasks
				process_dones(kq)
			} else if events[i].filter == (-1) {
				if events[i].flags & 32768 {
					close_conn(c)
					continue
				}
				// Read data
				n := C.read(c.fd, c.read_buf + c.read_len, 4096 - c.read_len)
				if n <= 0 {
					if n < 0 && (*__error()) != 35 && (*__error()) != 35 {
						close_conn(c)
					}
					continue
				}
				c.read_len += usize(n)
				// Find end of headers
				header_end := memmem(c.read_buf, c.read_len, c'\r\n\r\n', 4)
				if !header_end {
					if c.read_len >= 4096 {
						close_conn(c)
						// Headers too large
					}
					continue
				}
				// Simple parse: assume GET, no body
				if C.memcmp(c.read_buf, c'GET ', 4) != 0 {
					close_conn(c)
					continue
				}
				path_start := c.read_buf + 4
				path_end := C.strchr(path_start, ` `)
				if !path_end {
					close_conn(c)
					continue
				}
				path_len := path_end - path_start
				is_sleep := 0
				if path_len == 1 && C.memcmp(path_start, c'/', 1) == 0 {
					// / - fast path
				} else if path_len == 6 && C.memcmp(path_start, c'/sleep', 6) == 0 {
					is_sleep = 1
				} else {
					close_conn(c)
					continue
				}
				// Consume request, assume no extra data
				c.read_len = 0
				if is_sleep {
					// Disable read
					for {
						__kevp__ := (&ev)
						__kevp__.ident = (c.fd)
						__kevp__.filter = (-1)
						__kevp__.flags = (2)
						__kevp__.fflags = (0)
						__kevp__.data = (0)
						__kevp__.udata = c
						// while()
						if !(0) {
							break
						}
					}
					kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
					// Enqueue task
					t := C.malloc(sizeof(Task))
					t.c = c
					t.next = (unsafe { nil })
					pthread_mutex_lock(&task_mutex)
					if task_tail {
						task_tail.next = t
					} else {
						task_head = t
					}
					task_tail = t
					pthread_cond_signal(&task_cond)
					pthread_mutex_unlock(&task_mutex)
				} else {
					// Prepare response for /
					resp := C.malloc(4096)
					len := __builtin___snprintf_chk(resp, 4096, 0, __builtin_object_size(resp,
						if 2 > 1 { 1 } else { 0 }), c'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s',
						18, c'<b>hello world</b>')
					c.write_buf = resp
					c.write_len = len
					c.write_pos = 0
					// Try write
					w := C.write(c.fd, c.write_buf + c.write_pos, c.write_len - c.write_pos)
					if w > 0 {
						c.write_pos += usize(w)
					} else if w < 0 && (*__error()) != 35 && (*__error()) != 35 {
						close_conn(c)
						continue
					}
					if c.write_pos < c.write_len {
						for {
							__kevp__ := (&ev)
							__kevp__.ident = (c.fd)
							__kevp__.filter = (-2)
							__kevp__.flags = (1 | 32768)
							__kevp__.fflags = (0)
							__kevp__.data = (0)
							__kevp__.udata = c
							// while()
							if !(0) {
								break
							}
						}
						kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
					} else {
						C.free(c.write_buf)
						c.write_buf = (unsafe { nil })
						// Continue monitoring read
					}
				}
			} else if events[i].filter == (-2) {
				if events[i].flags & 32768 {
					close_conn(c)
					continue
				}
				// Write data
				w := C.write(c.fd, c.write_buf + c.write_pos, c.write_len - c.write_pos)
				if w > 0 {
					c.write_pos += usize(w)
				} else if w < 0 && (*__error()) != 35 && (*__error()) != 35 {
					close_conn(c)
					continue
				}
				if c.write_pos >= c.write_len {
					C.free(c.write_buf)
					c.write_buf = (unsafe { nil })
					// Disable write event
					for {
						__kevp__ := (&ev)
						__kevp__.ident = (c.fd)
						__kevp__.filter = (-2)
						__kevp__.flags = (2)
						__kevp__.fflags = (0)
						__kevp__.data = (0)
						__kevp__.udata = c
						// while()
						if !(0) {
							break
						}
					}
					kevent(kq, &ev, 1, (unsafe { nil }), 0, (unsafe { nil }))
					// For slow path, read was deleted, so add it back here
					// But for fast path, it was never deleted
					// To handle uniformly, we can check if read is enabled, but for simplicity, since slow adds back in process_dones
					// For fast, no need
					c.read_len = 0
				}
			}
		}
	}
	// Cleanup (not reached in this simple example)
	C.close(server_fd)
	C.close(kq)
	C.close(wake_pipe[0])
	C.close(wake_pipe[1])
	return
}

@[c: '__builtin___memset_chk']
fn builtin___memset_chk(arg0 voidptr, arg1 int, arg2 u32, arg3 u32) voidptr

@[c: '__builtin_constant_p']
fn builtin_constant_p() int
