module fasthttp

import net

#include <sys/event.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>

const initial_buf_size = 8192
const max_buf_size = 10 * 1024 * 1024 // 10MB max request size
const kqueue_max_events = 128
const backlog = max_connection_size

fn C.kevent(kq int, changelist &C.kevent, nchanges int, eventlist &C.kevent, nevents int, timeout &C.timespec) int
fn C.kqueue() int
fn C.fstat(fd int, buf &C.stat) int

// int sendfile(int fd, int s, off_t offset, off_t *len, struct sf_hdtr *hdtr, int flags);
fn C.sendfile(fd int, s int, offset i64, len &i64, hdtr voidptr, flags int) int

struct C.kevent {
	ident  u64
	filter i16
	flags  u16
	fflags u32
	data   isize
	udata  voidptr
}

// Helper to set fields of a kevent struct
fn ev_set(mut ev C.kevent, ident u64, filter i16, flags u16, fflags u32, data isize, udata voidptr) {
	ev.ident = ident
	ev.filter = filter
	ev.flags = flags
	ev.fflags = fflags
	ev.data = data
	ev.udata = udata
}

struct Conn {
	fd        int
	user_data voidptr
mut:
	read_buf  []u8
	read_len  int
	write_buf []u8
	write_pos int

	// Request parsing state
	headers_complete  bool
	content_length    int = -1 // -1 means not yet determined
	body_start_offset int     // byte offset where body begins

	// Sendfile state
	file_fd  int = -1
	file_len i64
	file_pos i64
}

pub struct Server {
pub mut:
	port            int
	socket_fd       int
	poll_fd         int // kqueue fd
	user_data       voidptr
	request_handler fn (HttpRequest) !HttpResponse @[required]
}

// new_server creates and initializes a new Server instance.
pub fn new_server(config ServerConfig) !&Server {
	mut server := &Server{
		port:            config.port
		user_data:       config.user_data
		request_handler: config.handler
	}
	return server
}

fn set_nonblocking(fd int) {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags == -1 {
		return
	}
	C.fcntl(fd, C.F_SETFL, flags | C.O_NONBLOCK)
}

fn add_event(kq int, ident u64, filter i16, flags u16, udata voidptr) int {
	mut ev := C.kevent{}
	ev_set(mut &ev, ident, filter, flags, u32(0), isize(0), udata)
	return C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })
}

fn delete_event(kq int, ident u64, filter i16, udata voidptr) {
	mut ev := C.kevent{}
	ev_set(mut &ev, ident, filter, u16(C.EV_DELETE), u32(0), isize(0), udata)
	C.kevent(kq, &ev, 1, unsafe { nil }, 0, unsafe { nil })
}

fn close_conn(kq int, c_ptr voidptr) {
	mut c := unsafe { &Conn(c_ptr) }
	delete_event(kq, u64(c.fd), i16(C.EVFILT_READ), c)
	delete_event(kq, u64(c.fd), i16(C.EVFILT_WRITE), c)
	C.close(c.fd)
	if c.write_buf.len > 0 {
		c.write_buf.clear()
	}
	if c.file_fd != -1 {
		C.close(c.file_fd)
		c.file_fd = -1
	}
	unsafe { free(c_ptr) }
}

fn send_pending(c_ptr voidptr) bool {
	mut c := unsafe { &Conn(c_ptr) }

	// 1. Send memory buffer (headers or small response)
	if c.write_pos < c.write_buf.len {
		remaining := c.write_buf.len - c.write_pos
		write_ptr := unsafe { &c.write_buf[0] + c.write_pos }
		sent := C.send(c.fd, write_ptr, remaining, 0)
		if sent > 0 {
			c.write_pos += int(sent)
		}
		if sent < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				return true
			}
			return false // Error
		}
	}

	// 2. Send file if buffer is fully sent
	if c.write_pos >= c.write_buf.len && c.file_fd != -1 {
		mut len := i64(0) // Input 0 means send until EOF
		ret := C.sendfile(c.file_fd, c.fd, c.file_pos, &len, unsafe { nil }, 0)

		if len > 0 {
			c.file_pos += len
		}

		if ret == -1 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				return true
			}
			// Error sending file
			C.close(c.file_fd)
			c.file_fd = -1
			return false
		}

		if c.file_pos >= c.file_len {
			// Done sending file
			C.close(c.file_fd)
			c.file_fd = -1
		} else {
			// Not done yet
			return true
		}
	}

	// Check if completely done (both buffer and file)
	if c.write_pos >= c.write_buf.len && c.file_fd == -1 {
		return false // Done
	}

	return true // Still pending (partial buffer write or file not done)
}

fn send_bad_request(fd int) {
	C.send(fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
}

fn handle_write(kq int, c_ptr voidptr) {
	mut c := unsafe { &Conn(c_ptr) }
	if send_pending(c_ptr) {
		return
	}
	delete_event(kq, u64(c.fd), i16(C.EVFILT_WRITE), c)
	close_conn(kq, c_ptr)
}

fn handle_read(mut s Server, kq int, c_ptr voidptr) {
	mut c := unsafe { &Conn(c_ptr) }

	// Edge-triggered kqueue: must read all available data in a loop
	for {
		// Ensure we have space to read - grow buffer if needed
		available := c.read_buf.len - c.read_len
		if available < 4096 {
			// Need more space, grow the buffer
			if c.read_buf.len >= max_buf_size {
				// Already at max size
				C.send(c.fd, status_413_response.data, status_413_response.len, 0)
				close_conn(kq, c_ptr)
				return
			}
			new_size := if c.read_buf.len * 2 > max_buf_size { max_buf_size } else { c.read_buf.len * 2 }
			// Create new larger buffer and copy existing data
			mut new_buf := []u8{len: new_size, cap: new_size}
			for j := 0; j < c.read_len; j++ {
				new_buf[j] = c.read_buf[j]
			}
			c.read_buf = new_buf
		}

		n := C.recv(c.fd, unsafe { &c.read_buf[c.read_len] }, c.read_buf.len - c.read_len, 0)
		if n <= 0 {
			if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
				// No more data available right now, continue processing what we have
				break
			}
			if n < 0 {
				// Unexpected recv error - send 444 No Response
				C.send(c.fd, status_444_response.data, status_444_response.len, 0)
			}
			// n == 0 means client closed, or error
			close_conn(kq, c_ptr)
			return
		}

		c.read_len += int(n)
	}

	if c.read_len == 0 {
		return
	}

	// Check if we have complete headers (look for \r\n\r\n)
	if !c.headers_complete {
		for i := 0; i <= c.read_len - 4; i++ {
			if c.read_buf[i] == `\r` && c.read_buf[i + 1] == `\n`
				&& c.read_buf[i + 2] == `\r` && c.read_buf[i + 3] == `\n` {
				c.headers_complete = true
				c.body_start_offset = i + 4
				// Parse Content-Length from headers
				c.content_length = parse_content_length(c.read_buf[..i], i)
				break
			}
		}
		if !c.headers_complete {
			// Headers not complete yet, wait for more data
			return
		}
	}

	// If we have Content-Length, check if we need to grow buffer and wait for full body
	if c.content_length > 0 {
		expected_total := c.body_start_offset + c.content_length
		// Check if request is too large
		if expected_total > max_buf_size {
			C.send(c.fd, status_413_response.data, status_413_response.len, 0)
			close_conn(kq, c_ptr)
			return
		}
		// Grow buffer if needed to fit expected content
		if expected_total > c.read_buf.len {
			mut new_buf := []u8{len: expected_total, cap: expected_total}
			for j := 0; j < c.read_len; j++ {
				new_buf[j] = c.read_buf[j]
			}
			c.read_buf = new_buf
		}
		if c.read_len < expected_total {
			// Body not complete yet, wait for more data
			return
		}
	}

	// Request is complete, process it
	mut req_buf := []u8{cap: c.read_len}
	unsafe {
		req_buf.push_many(&c.read_buf[0], c.read_len)
	}

	mut decoded := decode_http_request(req_buf) or {
		send_bad_request(c.fd)
		close_conn(kq, c_ptr)
		return
	}
	decoded.client_conn_fd = c.fd
	decoded.user_data = c.user_data

	resp := s.request_handler(decoded) or {
		send_bad_request(c.fd)
		close_conn(kq, c_ptr)
		return
	}

	c.write_buf = resp.content.clone()
	if resp.file_path != '' {
		fd := C.open(resp.file_path.str, C.O_RDONLY)
		if fd != -1 {
			mut st := C.stat{}
			if C.fstat(fd, &st) == 0 {
				c.file_fd = fd
				c.file_len = st.st_size
				c.file_pos = 0
			} else {
				C.close(fd)
			}
		}
	}

	c.write_pos = 0
	c.read_len = 0
	// Reset parsing state for potential keep-alive
	c.headers_complete = false
	c.content_length = -1
	c.body_start_offset = 0

	if send_pending(c_ptr) {
		add_event(kq, u64(c.fd), i16(C.EVFILT_WRITE), u16(C.EV_ADD | C.EV_ENABLE | C.EV_CLEAR),
			c)
		return
	}

	close_conn(kq, c_ptr)
}

// parse_content_length extracts the Content-Length value from HTTP headers
@[direct_array_access]
fn parse_content_length(header_buf []u8, header_len int) int {
	// Search for "Content-Length:" (case-insensitive)
	mut i := 0
	for i < header_len - 15 {
		// Check for "Content-Length:" (common case) or "content-length:"
		if (header_buf[i] == `C` || header_buf[i] == `c`)
			&& (header_buf[i + 1] == `o` || header_buf[i + 1] == `O`)
			&& (header_buf[i + 2] == `n` || header_buf[i + 2] == `N`)
			&& (header_buf[i + 3] == `t` || header_buf[i + 3] == `T`)
			&& (header_buf[i + 4] == `e` || header_buf[i + 4] == `E`)
			&& (header_buf[i + 5] == `n` || header_buf[i + 5] == `N`)
			&& (header_buf[i + 6] == `t` || header_buf[i + 6] == `T`)
			&& header_buf[i + 7] == `-`
			&& (header_buf[i + 8] == `L` || header_buf[i + 8] == `l`)
			&& (header_buf[i + 9] == `e` || header_buf[i + 9] == `E`)
			&& (header_buf[i + 10] == `n` || header_buf[i + 10] == `N`)
			&& (header_buf[i + 11] == `g` || header_buf[i + 11] == `G`)
			&& (header_buf[i + 12] == `t` || header_buf[i + 12] == `T`)
			&& (header_buf[i + 13] == `h` || header_buf[i + 13] == `H`)
			&& header_buf[i + 14] == `:` {
			// Found "Content-Length:", now parse the value
			mut j := i + 15
			// Skip whitespace
			for j < header_len && (header_buf[j] == ` ` || header_buf[j] == `\t`) {
				j++
			}
			// Parse number
			mut val := 0
			for j < header_len && header_buf[j] >= `0` && header_buf[j] <= `9` {
				val = val * 10 + int(header_buf[j] - `0`)
				j++
			}
			return val
		}
		i++
	}
	return 0
}

fn accept_clients(kq int, listen_fd int, user_data voidptr) {
	for {
		client_fd := C.accept(listen_fd, unsafe { nil }, unsafe { nil })
		if client_fd < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break
			}
			C.perror(c'accept')
			break
		}
		set_nonblocking(client_fd)
		mut c := &Conn{
			fd:        client_fd
			user_data: user_data
			read_buf:  []u8{len: initial_buf_size, cap: initial_buf_size}
			file_fd:   -1
		}
		add_event(kq, u64(client_fd), i16(C.EVFILT_READ), u16(C.EV_ADD | C.EV_ENABLE | C.EV_CLEAR),
			c)
	}
}

// run starts the server and enters the main event loop (Kqueue version).
pub fn (mut s Server) run() ! {
	s.socket_fd = C.socket(net.AddrFamily.ip, net.SocketType.tcp, 0)
	if s.socket_fd < 0 {
		C.perror(c'socket')
		return error('socket creation failed')
	}

	opt := 1
	C.setsockopt(s.socket_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(int))

	addr := net.new_ip(u16(s.port), [u8(0), 0, 0, 0]!)
	alen := addr.len()

	if C.bind(s.socket_fd, voidptr(&addr), alen) < 0 {
		C.perror(c'bind')
		return error('socket bind failed')
	}
	if C.listen(s.socket_fd, backlog) < 0 {
		C.perror(c'listen')
		return error('socket listen failed')
	}

	set_nonblocking(s.socket_fd)

	s.poll_fd = C.kqueue()
	if s.poll_fd < 0 {
		C.perror(c'kqueue')
		return error('kqueue creation failed')
	}

	add_event(s.poll_fd, u64(s.socket_fd), i16(C.EVFILT_READ), u16(C.EV_ADD | C.EV_ENABLE | C.EV_CLEAR),
		unsafe { nil })

	println('listening on http://localhost:${s.port}/')

	mut events := [kqueue_max_events]C.kevent{}
	for {
		nev := C.kevent(s.poll_fd, unsafe { nil }, 0, &events[0], kqueue_max_events, unsafe { nil })
		if nev < 0 {
			C.perror(c'kevent')
			break
		}

		for i := 0; i < nev; i++ {
			event := events[i]
			if event.flags & u16(C.EV_ERROR) != 0 {
				if event.ident == u64(s.socket_fd) {
					C.perror(c'listener error')
					continue
				}
				if event.udata != unsafe { nil } {
					close_conn(s.poll_fd, event.udata)
				}
				continue
			}

			if event.ident == u64(s.socket_fd) {
				accept_clients(s.poll_fd, s.socket_fd, s.user_data)
				continue
			}

			if event.udata == unsafe { nil } {
				continue
			}

			if event.flags & u16(C.EV_EOF) != 0 {
				close_conn(s.poll_fd, event.udata)
				continue
			}

			if event.filter == i16(C.EVFILT_READ) {
				handle_read(mut s, s.poll_fd, event.udata)
			} else if event.filter == i16(C.EVFILT_WRITE) {
				handle_write(s.poll_fd, event.udata)
			}
		}
	}

	C.close(s.socket_fd)
	C.close(s.poll_fd)
}
