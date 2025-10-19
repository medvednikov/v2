import os
import time
// import net
import term

// V's libc module provides access to C standard library functions
#flag -I @vlib/v/libc
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>

// Explicit C function definitions
fn C.socket(domain int, typ int, protocol int) int
fn C.setsockopt(sockfd int, level int, optname int, optval voidptr, optlen u32) int
fn C.bind(sockfd int, addr voidptr, addrlen u32) int
fn C.listen(sockfd int, backlog int) int
fn C.accept(sockfd int, addr voidptr, addrlen voidptr) int
fn C.fcntl(fd int, cmd int, arg int) int
fn C.kqueue() int
fn C.kevent(kq int, changelist &C.kevent, nchanges int, eventlist &C.kevent, nevents int, timeout &C.timespec) int
fn C.pipe(pipefd &int) int
fn C.close(fd int) int
fn C.read(fd int, buf voidptr, count int) int
fn C.write(fd int, buf voidptr, count int) int
fn C.malloc(size int) voidptr
fn C.free(ptr voidptr)
fn C.memset(dest voidptr, ch int, count int) voidptr
fn C.memcmp(s1 voidptr, s2 voidptr, n int) int
fn C.memmem(haystack voidptr, haystacklen int, needle voidptr, needlelen int) voidptr
fn C.strchr(s &u8, c int) &u8

// fn C.snprintf(str voidptr, size int, format string, ...) int
fn C.perror(s &char)
fn C.pthread_create(thread &C.pthread_t, attr voidptr, start_routine fn (voidptr) voidptr, arg voidptr) int
fn C.pthread_mutex_init(mutex &C.pthread_mutex_t, attr voidptr) int
fn C.pthread_mutex_lock(mutex &C.pthread_mutex_t) int
fn C.pthread_mutex_unlock(mutex &C.pthread_mutex_t) int
fn C.pthread_cond_init(cond &C.pthread_cond_t, attr voidptr) int
fn C.pthread_cond_wait(cond &C.pthread_cond_t, mutex &C.pthread_mutex_t) int
fn C.pthread_cond_signal(cond &C.pthread_cond_t) int

const port = 8092
const backlog = 128
const buf_size = 4096
const num_threads = 8
const body = '<b>hello world</b>'
const body_len = body.len // Use V's built-in len property

// Struct to hold connection-specific data
struct Conn {
mut:
	fd        int
	read_buf  [buf_size]u8
	read_len  int
	write_buf voidptr
	write_len int
	write_pos int
}

// Task for the worker thread pool
struct Task {
mut:
	c    &Conn
	next &Task
}

// Completed task data
struct Done {
mut:
	c    &Conn
	resp voidptr
	len  int
	next &Done
}

// Shared data for worker threads
struct WorkerData {
mut:
	task_mutex C.pthread_mutex_t
	task_cond  C.pthread_cond_t
	task_head  &Task
	task_tail  &Task
	done_mutex C.pthread_mutex_t
	done_head  &Done
	done_tail  &Done
	quit       bool
	wake_pipe  [2]int
}

struct C.kevent {
	// The fields below are for reference and are not defined in the V code.
	// Their exact size and order can vary slightly by operating system.
	ident  u64     // Identifier for this event (e.g., file descriptor, process ID)
	filter i16     // Filter for event (e.g., EVFILT_READ, EVFILT_WRITE)
	flags  u16     // General flags (e.g., EV_ADD, EV_DELETE)
	fflags u32     // Filter-specific flags
	data   isize   // Filter-specific data
	udata  voidptr // Opaque user data identifier
}

// Helper to set fields of a kevent struct, replacing the C macro EV_SET
fn ev_set(mut ev C.kevent, ident u64, filter i16, flags u16, fflags u32, data isize, udata voidptr) {
	ev.ident = ident
	ev.filter = filter
	ev.flags = flags
	ev.fflags = fflags
	ev.data = data
	ev.udata = udata
}

fn close_conn(c &Conn) {
	if c.write_buf != unsafe { nil } {
		C.free(c.write_buf)
	}
	C.close(c.fd)
	unsafe { C.free(c) }
}

fn worker_func(arg voidptr) voidptr {
	mut w := unsafe { &WorkerData(arg) }
	for {
		C.pthread_mutex_lock(&w.task_mutex)
		for w.task_head == unsafe { nil } && !w.quit {
			C.pthread_cond_wait(&w.task_cond, &w.task_mutex)
		}
		if w.quit && w.task_head == unsafe { nil } {
			C.pthread_mutex_unlock(&w.task_mutex)
			break
		}
		mut t := w.task_head
		w.task_head = t.next
		if w.task_head == unsafe { nil } {
			w.task_tail = unsafe { nil }
		}
		C.pthread_mutex_unlock(&w.task_mutex)

		// Process sleep
		time.sleep(5 * time.second)

		// Prepare response
		resp := C.malloc(buf_size)
		// Use a C-style format string and pass the V string's C representation with .str
		format_str := c'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s'
		len := C.snprintf(resp, buf_size, format_str, body_len, body.str)

		// Enqueue done
		mut d := unsafe { &Done(C.malloc(sizeof(Done))) }
		d.c = t.c
		d.resp = resp
		d.len = int(len)
		d.next = unsafe { nil }

		C.pthread_mutex_lock(&w.done_mutex)
		if w.done_tail != unsafe { nil } {
			w.done_tail.next = d
		} else {
			w.done_head = d
		}
		w.done_tail = d
		C.pthread_mutex_unlock(&w.done_mutex)

		// Wake IO thread
		x := u8(`x`)
		C.write(w.wake_pipe[1], &x, 1)

		unsafe { C.free(t) }
	}
	return unsafe { nil }
}

fn process_dones(kq int, mut w WorkerData) {
	C.pthread_mutex_lock(&w.done_mutex)
	mut local_head := w.done_head
	w.done_head = unsafe { nil }
	w.done_tail = unsafe { nil }
	C.pthread_mutex_unlock(&w.done_mutex)

	for local_head != unsafe { nil } {
		d := local_head
		local_head = d.next

		mut c := d.c
		c.write_buf = d.resp
		c.write_len = d.len
		c.write_pos = 0

		// Try to write immediately
		// Pointer arithmetic must be done on typed pointers inside an unsafe block
		write_ptr := unsafe { &u8(c.write_buf) + c.write_pos }
		written := C.write(c.fd, write_ptr, c.write_len - c.write_pos)
		if written > 0 {
			c.write_pos += int(written)
		} else if written < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
			close_conn(c)
			unsafe { C.free(d) }
			continue
		}

		if c.write_pos < c.write_len {
			// Add write event
			mut ev := C.kevent{}
			ev_set(mut &ev, u64(c.fd), i16(C.EVFILT_WRITE), u16(C.EV_ADD | C.EV_EOF),
				u32(0), isize(0), c)
			C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })
		} else {
			C.free(c.write_buf)
			c.write_buf = unsafe { nil }
			// Add back read event
			mut ev := C.kevent{}
			ev_set(mut &ev, u64(c.fd), i16(C.EVFILT_READ), u16(C.EV_ADD | C.EV_EOF), u32(0),
				isize(0), c)
			C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })
			c.read_len = 0
		}

		unsafe { C.free(d) }
	}
}

fn C.bind(sockfd int, addr &C.sockaddr_in, addrlen u32) int

pub struct C.sockaddr_in {
mut:
	sin_len    u8
	sin_family u8
	sin_port   u16
	sin_addr   u32
	sin_zero   [8]char
}

const C.AF_INET u8

fn C.htons(__hostshort u16) u16

fn main() {
	// Create server socket
	// server_fd := C.socket(.ip, .tcp, 0)
	server_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if server_fd < 0 {
		C.perror(c'socket')
		return
	}

	opt := 1
	C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(int))

	mut addr := C.sockaddr_in{}
	C.memset(&addr, 0, sizeof(addr))
	addr.sin_family = C.AF_INET // u16(net.af_inet)
	// TODO
	// addr.sin_addr.s_addr = C.INADDR_ANY
	addr.sin_port = C.htons(port)

	if C.bind(server_fd, &addr, sizeof(addr)) < 0 {
		C.perror(c'bind')
		return
	}

	if C.listen(server_fd, backlog) < 0 {
		C.perror(c'listen')
		return
	}

	C.fcntl(server_fd, C.F_SETFL, C.O_NONBLOCK)

	// Create kqueue
	kq := C.kqueue()
	if kq < 0 {
		C.perror(c'kqueue')
		return
	}

	mut ev := C.kevent{}
	ev_set(mut &ev, u64(server_fd), i16(C.EVFILT_READ), u16(C.EV_ADD), u32(0), isize(0),
		unsafe { nil })
	C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })

	// Initialize worker data
	mut worker_data := WorkerData{
		task_head: unsafe { nil }
		task_tail: unsafe { nil }
		done_head: unsafe { nil }
		done_tail: unsafe { nil }
	}
	C.pthread_mutex_init(&worker_data.task_mutex, unsafe { nil })
	C.pthread_cond_init(&worker_data.task_cond, unsafe { nil })
	C.pthread_mutex_init(&worker_data.done_mutex, unsafe { nil })

	// Create wake pipe
	if C.pipe(&worker_data.wake_pipe[0]) < 0 {
		C.perror(c'pipe')
		return
	}
	C.fcntl(worker_data.wake_pipe[0], C.F_SETFL, C.O_NONBLOCK)
	C.fcntl(worker_data.wake_pipe[1], C.F_SETFL, C.O_NONBLOCK)
	ev_set(mut &ev, u64(worker_data.wake_pipe[0]), i16(C.EVFILT_READ), u16(C.EV_ADD),
		u32(0), isize(0), unsafe { nil })
	C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })

	// Create worker threads
	threads := [num_threads]C.pthread_t{}
	for i := 0; i < num_threads; i++ {
		C.pthread_create(&threads[i], unsafe { nil }, worker_func, &worker_data)
	}

	// Event loop
	events := [64]C.kevent{}
	for {
		nev := C.kevent(kq, unsafe { nil }, 0, &events[0], 64, unsafe { nil })
		if nev < 0 {
			C.perror(c'kevent')
			break
		}

		for i := 0; i < nev; i++ {
			event := events[i]
			mut c := unsafe { &Conn(event.udata) }

			ident := event.ident
			filter := event.filter
			flags := event.flags

			if flags & u16(C.EV_ERROR) != 0 {
				if c != unsafe { nil } {
					close_conn(c)
				}
				continue
			}

			if ident == u64(server_fd) && filter == i16(C.EVFILT_READ) {
				// Accept new connection
				client_fd := C.accept(server_fd, unsafe { nil }, unsafe { nil })
				if client_fd < 0 {
					continue
				}

				mut new_c := unsafe { &Conn(C.malloc(sizeof(Conn))) }
				C.memset(new_c, 0, sizeof(Conn))
				new_c.fd = client_fd
				C.fcntl(new_c.fd, C.F_SETFL, C.O_NONBLOCK)

				ev_set(mut &ev, u64(new_c.fd), i16(C.EVFILT_READ), u16(C.EV_ADD | C.EV_EOF),
					u32(0), isize(0), new_c)
				C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })
			} else if ident == u64(worker_data.wake_pipe[0]) && filter == i16(C.EVFILT_READ) {
				// Drain pipe
				buf := [1024]u8{}
				for C.read(worker_data.wake_pipe[0], &buf[0], sizeof(buf)) > 0 {}
				// Process completed tasks
				process_dones(kq, mut worker_data)
			} else if filter == i16(C.EVFILT_READ) {
				if flags & u16(C.EV_EOF) != 0 {
					close_conn(c)
					continue
				}

				// Read data
				n := C.read(c.fd, &c.read_buf[c.read_len], buf_size - c.read_len)
				if n <= 0 {
					if n < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
						close_conn(c)
					}
					continue
				}
				c.read_len += int(n)

				// Find end of headers
				header_end := C.memmem(&c.read_buf[0], c.read_len, c'\r\n\r\n', 4)
				if header_end == unsafe { nil } {
					if c.read_len >= buf_size {
						close_conn(c) // Headers too large
					}
					continue
				}

				// Simple parse: assume GET, no body
				if C.memcmp(&c.read_buf[0], c'GET ', 4) != 0 {
					close_conn(c)
					continue
				}

				path_start := &c.read_buf[4]
				path_end := C.strchr(path_start, ` `)
				if path_end == unsafe { nil } {
					close_conn(c)
					continue
				}

				path_len := path_end - path_start
				mut is_sleep := false
				if path_len == 1 && C.memcmp(path_start, c'/', 1) == 0 {
					// / - fast path
				} else if path_len == 6 && C.memcmp(path_start, c'/sleep', 6) == 0 {
					is_sleep = true
				} else {
					close_conn(c)
					continue
				}

				// Consume request, assume no extra data
				c.read_len = 0

				if is_sleep {
					// Disable read
					ev_set(mut &ev, u64(c.fd), i16(C.EVFILT_READ), u16(C.EV_DELETE), u32(0),
						isize(0), c)
					C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })

					// Enqueue task
					mut t := unsafe { &Task(C.malloc(sizeof(Task))) }
					t.c = c
					t.next = unsafe { nil }

					C.pthread_mutex_lock(&worker_data.task_mutex)
					if worker_data.task_tail != unsafe { nil } {
						worker_data.task_tail.next = t
					} else {
						worker_data.task_head = t
					}
					worker_data.task_tail = t
					C.pthread_cond_signal(&worker_data.task_cond)
					C.pthread_mutex_unlock(&worker_data.task_mutex)
				} else {
					// Prepare response for /
					resp := C.malloc(buf_size)
					format_str := c'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s'
					len := C.snprintf(resp, buf_size, format_str, body_len, body.str)

					c.write_buf = resp
					c.write_len = int(len)
					c.write_pos = 0

					// Try write
					write_ptr := unsafe { &u8(c.write_buf) + c.write_pos }
					written := C.write(c.fd, write_ptr, c.write_len - c.write_pos)
					if written > 0 {
						c.write_pos += int(written)
					} else if written < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
						close_conn(c)
						continue
					}

					if c.write_pos < c.write_len {
						ev_set(mut &ev, u64(c.fd), i16(C.EVFILT_WRITE), u16(C.EV_ADD | C.EV_EOF),
							u32(0), isize(0), c)
						C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })
					} else {
						C.free(c.write_buf)
						c.write_buf = unsafe { nil }
						// Continue monitoring read
					}
				}
			} else if filter == i16(C.EVFILT_WRITE) {
				if flags & u16(C.EV_EOF) != 0 {
					close_conn(c)
					continue
				}

				// Write data
				write_ptr := unsafe { &u8(c.write_buf) + c.write_pos }
				written := C.write(c.fd, write_ptr, c.write_len - c.write_pos)
				if written > 0 {
					c.write_pos += int(written)
				} else if written < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
					close_conn(c)
					continue
				}

				if c.write_pos >= c.write_len {
					C.free(c.write_buf)
					c.write_buf = unsafe { nil }

					// Disable write event
					ev_set(mut &ev, u64(c.fd), i16(C.EVFILT_WRITE), u16(C.EV_DELETE),
						u32(0), isize(0), c)
					C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })

					c.read_len = 0
				}
			}
		}
	}

	// Cleanup (not reached in this simple example)
	C.close(server_fd)
	C.close(kq)
	C.close(worker_data.wake_pipe[0])
	C.close(worker_data.wake_pipe[1])
}
