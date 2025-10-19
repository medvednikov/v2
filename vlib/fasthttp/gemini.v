import os
import time
import net
import term
import sync

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

const (
	port        = 8092
	backlog     = 128
	buf_size    = 4096
	num_threads = 8
	body        = '<b>hello world</b>'
	body_len    = 18
)

struct Conn {
mut:
	fd        int
	read_buf  [buf_size]u8
	read_len  int
	write_buf voidptr
	write_len int
	write_pos int
}

struct Task {
mut:
	c    &Conn
	next &Task
}

struct Done {
mut:
	c    &Conn
	resp voidptr
	len  int
	next &Done
}

struct Worker {
mut:
	task_mutex sync.Mutex
	task_cond  sync.Cond
	task_head  &Task
	task_tail  &Task
	done_mutex sync.Mutex
	done_head  &Done
	done_tail  &Done
	quit       bool
	wake_pipe  [2]int
}

fn close_conn(c &Conn) {
	if c.write_buf != 0 {
		unsafe { C.free(c.write_buf) }
	}
	C.close(c.fd)
	unsafe { C.free(c) }
}

fn worker_func(mut w Worker) {
	for {
		w.task_mutex.lock()
		for w.task_head == 0 && !w.quit {
			w.task_cond.wait(&w.task_mutex)
		}
		if w.quit && w.task_head == 0 {
			w.task_mutex.unlock()
			break
		}
		t := w.task_head
		w.task_head = t.next
		if w.task_head == 0 {
			w.task_tail = 0
		}
		w.task_mutex.unlock()

		// Process sleep
		time.sleep(5 * time.second)

		// Prepare response
		resp := unsafe { C.malloc(buf_size) }
		len := C.snprintf(resp, buf_size,
			'HTTP/1.1 200 OK\r\n' +
			'Content-Type: text/html\r\n' +
			'Content-Length: %d\r\n' +
			'Connection: keep-alive\r\n\r\n' +
			'%s', body_len, body.str)

		// Enqueue done
		d := unsafe { &Done(C.malloc(sizeof(Done))) }
		d.c = t.c
		d.resp = resp
		d.len = int(len)
		d.next = 0

		w.done_mutex.lock()
		if w.done_tail != 0 {
			w.done_tail.next = d
		} else {
			w.done_head = d
		}
		w.done_tail = d
		w.done_mutex.unlock()

		// Wake IO thread
		x := 'x'
		C.write(w.wake_pipe[1], &x, 1)

		unsafe { C.free(t) }
	}
}

fn process_dones(kq int, mut w Worker) {
	w.done_mutex.lock()
	mut local_head := w.done_head
	w.done_head = 0
	w.done_tail = 0
	w.done_mutex.unlock()

	for local_head != 0 {
		d := local_head
		local_head = d.next

		c := d.c
		c.write_buf = d.resp
		c.write_len = d.len
		c.write_pos = 0

		// Try to write immediately
		written := C.write(c.fd, c.write_buf + c.write_pos, c.write_len - c.write_pos)
		if written > 0 {
			c.write_pos += int(written)
		} else if written < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
			close_conn(c)
			unsafe { C.free(d) }
			continue
		}

		if c.write_pos < c.write_len {
			// Add write event
			ev := C.struct_kevent{}
			C.EV_SET(&ev, c.fd, C.EVFILT_WRITE, C.EV_ADD | C.EV_EOF, 0, 0, c)
			C.kevent(kq, &ev, 1, 0, 0, 0)
		} else {
			unsafe { C.free(c.write_buf) }
			c.write_buf = 0
			// Add back read event
			ev := C.struct_kevent{}
			C.EV_SET(&ev, c.fd, C.EVFILT_READ, C.EV_ADD | C.EV_EOF, 0, 0, c)
			C.kevent(kq, &ev, 1, 0, 0, 0)
			c.read_len = 0
		}

		unsafe { C.free(d) }
	}
}

fn main() {
	// Create server socket
	server_fd := C.socket(C.AF_INET, C.SOCK_STREAM, 0)
	if server_fd < 0 {
		C.perror('socket')
		return
	}

	opt := 1
	C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(int))

	addr := C.struct_sockaddr_in{}
	C.memset(&addr, 0, sizeof(addr))
	addr.sin_family = C.AF_INET
	addr.sin_addr.s_addr = C.INADDR_ANY
	addr.sin_port = C.htons(port)

	if C.bind(server_fd, &addr, sizeof(addr)) < 0 {
		C.perror('bind')
		return
	}

	if C.listen(server_fd, backlog) < 0 {
		C.perror('listen')
		return
	}

	C.fcntl(server_fd, C.F_SETFL, C.O_NONBLOCK)

	// Create kqueue
	kq := C.kqueue()
	if kq < 0 {
		C.perror('kqueue')
		return
	}

	ev := C.struct_kevent{}
	C.EV_SET(&ev, server_fd, C.EVFILT_READ, C.EV_ADD, 0, 0, 0)
	C.kevent(kq, &ev, 1, 0, 0, 0)

	// Create wake pipe
	mut worker := Worker{}
	if C.pipe(&worker.wake_pipe[0]) < 0 {
		C.perror('pipe')
		return
	}
	C.fcntl(worker.wake_pipe[0], C.F_SETFL, C.O_NONBLOCK)
	C.fcntl(worker.wake_pipe[1], C.F_SETFL, C.O_NONBLOCK)
	C.EV_SET(&ev, worker.wake_pipe[0], C.EVFILT_READ, C.EV_ADD, 0, 0, 0)
	C.kevent(kq, &ev, 1, 0, 0, 0)

	// Create worker threads
	for i := 0; i < num_threads; i++ {
		go worker_func(mut worker)
	}

	// Event loop
	events := [64]C.struct_kevent{}
	for {
		nev := C.kevent(kq, 0, 0, &events[0], 64, 0)
		if nev < 0 {
			C.perror('kevent')
			break
		}

		for i := 0; i < nev; i++ {
			c := &Conn(events[i].udata)

			if events[i].flags & C.EV_ERROR != 0 {
				if c != 0 {
					close_conn(c)
				}
				continue
			}

			if events[i].ident == u64(server_fd) && events[i].filter == C.EVFILT_READ {
				// Accept new connection
				client_fd := C.accept(server_fd, 0, 0)
				if client_fd < 0 {
					continue
				}

				new_c := &Conn(unsafe { C.malloc(sizeof(Conn)) })
				C.memset(new_c, 0, sizeof(Conn))
				new_c.fd = client_fd
				C.fcntl(new_c.fd, C.F_SETFL, C.O_NONBLOCK)

				C.EV_SET(&ev, new_c.fd, C.EVFILT_READ, C.EV_ADD | C.EV_EOF, 0, 0, new_c)
				C.kevent(kq, &ev, 1, 0, 0, 0)
			} else if events[i].ident == u64(worker.wake_pipe[0]) && events[i].filter == C.EVFILT_READ {
				// Drain pipe
				buf := [1024]u8{}
				for C.read(worker.wake_pipe[0], &buf[0], sizeof(buf)) > 0 {}
				// Process completed tasks
				process_dones(kq, mut worker)
			} else if events[i].filter == C.EVFILT_READ {
				if events[i].flags & C.EV_EOF != 0 {
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
				header_end := C.memmem(&c.read_buf[0], c.read_len, '\r\n\r\n', 4)
				if header_end == 0 {
					if c.read_len >= buf_size {
						close_conn(c) // Headers too large
					}
					continue
				}

				// Simple parse: assume GET, no body
				if C.memcmp(&c.read_buf[0], 'GET ', 4) != 0 {
					close_conn(c)
					continue
				}

				path_start := &c.read_buf[4]
				path_end := C.strchr(path_start, ` `)
				if path_end == 0 {
					close_conn(c)
					continue
				}

				path_len := path_end - path_start
				mut is_sleep := false
				if path_len == 1 && C.memcmp(path_start, '/', 1) == 0 {
					// / - fast path
				} else if path_len == 6 && C.memcmp(path_start, '/sleep', 6) == 0 {
					is_sleep = true
				} else {
					close_conn(c)
					continue
				}

				// Consume request, assume no extra data
				c.read_len = 0

				if is_sleep {
					// Disable read
					C.EV_SET(&ev, c.fd, C.EVFILT_READ, C.EV_DELETE, 0, 0, c)
					C.kevent(kq, &ev, 1, 0, 0, 0)

					// Enqueue task
					t := &Task(unsafe { C.malloc(sizeof(Task)) })
					t.c = c
					t.next = 0

					worker.task_mutex.lock()
					if worker.task_tail != 0 {
						worker.task_tail.next = t
					} else {
						worker.task_head = t
					}
					worker.task_tail = t
					worker.task_cond.signal()
					worker.task_mutex.unlock()
				} else {
					// Prepare response for /
					resp := unsafe { C.malloc(buf_size) }
					len := C.snprintf(resp, buf_size,
						'HTTP/1.1 200 OK\r\n' +
						'Content-Type: text/html\r\n' +
						'Content-Length: %d\r\n' +
						'Connection: keep-alive\r\n\r\n' +
						'%s', body_len, body.str)

					c.write_buf = resp
					c.write_len = int(len)
					c.write_pos = 0

					// Try write
					written := C.write(c.fd, c.write_buf + c.write_pos, c.write_len - c.write_pos)
					if written > 0 {
						c.write_pos += int(written)
					} else if written < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
						close_conn(c)
						continue
					}

					if c.write_pos < c.write_len {
						C.EV_SET(&ev, c.fd, C.EVFILT_WRITE, C.EV_ADD | C.EV_EOF, 0, 0, c)
						C.kevent(kq, &ev, 1, 0, 0, 0)
					} else {
						unsafe { C.free(c.write_buf) }
						c.write_buf = 0
						// Continue monitoring read
					}
				}
			} else if events[i].filter == C.EVFILT_WRITE {
				if events[i].flags & C.EV_EOF != 0 {
					close_conn(c)
					continue
				}

				// Write data
				written := C.write(c.fd, c.write_buf + c.write_pos, c.write_len - c.write_pos)
				if written > 0 {
					c.write_pos += int(written)
				} else if written < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK {
					close_conn(c)
					continue
				}

				if c.write_pos >= c.write_len {
					unsafe { C.free(c.write_buf) }
					c.write_buf = 0

					// Disable write event
					C.EV_SET(&ev, c.fd, C.EVFILT_WRITE, C.EV_DELETE, 0, 0, c)
					C.kevent(kq, &ev, 1, 0, 0, 0)

					c.read_len = 0
				}
			}
		}
	}

	// Cleanup
	C.close(server_fd)
	C.close(kq)
	C.close(worker.wake_pipe[0])
	C.close(worker.wake_pipe[1])
}
