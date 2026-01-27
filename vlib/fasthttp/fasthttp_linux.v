module fasthttp

import net

#include <sys/epoll.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <netinet/tcp.h>

fn C.accept4(sockfd int, addr &net.Addr, addrlen &u32, flags int) int

fn C.epoll_create1(__flags int) int

fn C.epoll_ctl(__epfd int, __op int, __fd int, __event &C.epoll_event) int

fn C.epoll_wait(__epfd int, __events &C.epoll_event, __maxevents int, __timeout int) int

fn C.sendfile(out_fd int, in_fd int, offset &i64, count usize) int

fn C.fstat(fd int, buf &C.stat) int

@[typedef]
union C.epoll_data_t {
	ptr voidptr
	fd  int
	u32 u32
	u64 u64
}

struct C.epoll_event {
	events u32
	data   C.epoll_data_t
}

const initial_buf_size = 8192
const max_buf_size = 10 * 1024 * 1024 // 10MB max request size

struct Conn {
	fd        int
	user_data voidptr
mut:
	read_buf          []u8
	read_len          int
	headers_complete  bool
	content_length    int = -1 // -1 means not yet determined
	body_start_offset int      // byte offset where body begins
}

struct Server {
pub:
	port                    int = 3000
	max_request_buffer_size int = 8192
	user_data               voidptr
mut:
	listen_fds      []int    = []int{len: max_thread_pool_size, cap: max_thread_pool_size}
	epoll_fds       []int    = []int{len: max_thread_pool_size, cap: max_thread_pool_size}
	threads         []thread = []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	request_handler fn (HttpRequest) !HttpResponse @[required]
}

// new_server creates and initializes a new Server instance.
pub fn new_server(config ServerConfig) !&Server {
	if config.max_request_buffer_size <= 0 {
		return error('max_request_buffer_size must be greater than 0')
	}
	mut server := &Server{
		port:                    config.port
		max_request_buffer_size: config.max_request_buffer_size
		user_data:               config.user_data
		request_handler:         config.handler
	}
	unsafe {
		server.listen_fds.flags.set(.noslices | .noshrink | .nogrow)
		server.epoll_fds.flags.set(.noslices | .noshrink | .nogrow)
		server.threads.flags.set(.noslices | .noshrink | .nogrow)
	}
	return server
}

fn set_blocking(fd int, blocking bool) {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags == -1 {
		// TODO: better error handling
		eprintln(@LOCATION)
		return
	}
	if blocking {
		// This removes the O_NONBLOCK flag from flags and set it.
		C.fcntl(fd, C.F_SETFL, flags & ~C.O_NONBLOCK)
	} else {
		// This adds the O_NONBLOCK flag from flags and set it.
		C.fcntl(fd, C.F_SETFL, flags | C.O_NONBLOCK)
	}
}

fn close_socket(fd int) bool {
	ret := C.close(fd)
	if ret == -1 {
		if C.errno == C.EINTR {
			// Interrupted by signal, retry is safe
			return close_socket(fd)
		}
		eprintln('ERROR: close(fd=${fd}) failed with errno=${C.errno}')
		return false
	}
	return true
}

fn create_server_socket(port int) int {
	// Create a socket with non-blocking mode
	server_fd := C.socket(net.AddrFamily.ip, net.SocketType.tcp, 0)
	if server_fd < 0 {
		eprintln(@LOCATION)
		C.perror(c'Socket creation failed')
		return -1
	}

	set_blocking(server_fd, false)

	// Enable SO_REUSEADDR and SO_REUSEPORT
	opt := 1
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(opt)) < 0 {
		eprintln(@LOCATION)
		C.perror(c'setsockopt SO_REUSEADDR failed')
		close_socket(server_fd)
		return -1
	}
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEPORT, &opt, sizeof(opt)) < 0 {
		eprintln(@LOCATION)
		C.perror(c'setsockopt SO_REUSEPORT failed')
		close_socket(server_fd)
		return -1
	}

	addr := net.new_ip(u16(port), [u8(0), 0, 0, 0]!)
	alen := addr.len()
	if C.bind(server_fd, voidptr(&addr), alen) < 0 {
		eprintln(@LOCATION)
		C.perror(c'Bind failed')
		close_socket(server_fd)
		return -1
	}
	if C.listen(server_fd, max_connection_size) < 0 {
		eprintln(@LOCATION)
		C.perror(c'Listen failed')
		close_socket(server_fd)
		return -1
	}
	return server_fd
}

// Function to add a file descriptor to the epoll instance with Conn pointer
fn add_conn_to_epoll(epoll_fd int, conn &Conn, events u32) int {
	mut ev := C.epoll_event{
		events: events
	}
	ev.data.ptr = voidptr(conn)
	if C.epoll_ctl(epoll_fd, C.EPOLL_CTL_ADD, conn.fd, &ev) == -1 {
		eprintln(@LOCATION)
		C.perror(c'epoll_ctl')
		return -1
	}
	return 0
}

// Function to add a listen socket to the epoll instance (with nil pointer to distinguish from connections)
fn add_listen_fd_to_epoll(epoll_fd int, listen_fd int, events u32) int {
	mut ev := C.epoll_event{
		events: events
	}
	ev.data.ptr = unsafe { nil }
	if C.epoll_ctl(epoll_fd, C.EPOLL_CTL_ADD, listen_fd, &ev) == -1 {
		eprintln(@LOCATION)
		C.perror(c'epoll_ctl')
		return -1
	}
	return 0
}

// Function to remove a file descriptor from the epoll instance
fn remove_fd_from_epoll(epoll_fd int, fd int) bool {
	ret := C.epoll_ctl(epoll_fd, C.EPOLL_CTL_DEL, fd, C.NULL)
	if ret == -1 {
		eprintln('ERROR: epoll_ctl(DEL, fd=${fd}) failed with errno=${C.errno}')
		return false
	}
	return true
}

// Close connection and free Conn struct
fn close_conn(epoll_fd int, conn_ptr voidptr) {
	mut c := unsafe { &Conn(conn_ptr) }
	remove_fd_from_epoll(epoll_fd, c.fd)
	close_socket(c.fd)
	unsafe { free(conn_ptr) }
}

fn handle_accept_loop(epoll_fd int, listen_fd int, user_data voidptr) {
	for {
		client_fd := C.accept4(listen_fd, C.NULL, C.NULL, C.SOCK_NONBLOCK)
		if client_fd < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break // No more incoming connections; exit loop.
			}
			eprintln(@LOCATION)
			C.perror(c'Accept failed')
			break
		}
		// Enable TCP_NODELAY for lower latency
		opt := 1
		C.setsockopt(client_fd, C.IPPROTO_TCP, C.TCP_NODELAY, &opt, sizeof(opt))
		// Create Conn struct for this connection
		mut conn := &Conn{
			fd:        client_fd
			user_data: user_data
			read_buf:  []u8{len: initial_buf_size, cap: initial_buf_size}
		}
		// Register client socket with epoll
		if add_conn_to_epoll(epoll_fd, conn, u32(C.EPOLLIN | C.EPOLLET)) == -1 {
			close_socket(client_fd)
			unsafe { free(conn) }
		}
	}
}

fn handle_client_closure(epoll_fd int, conn_ptr voidptr) {
	if conn_ptr == unsafe { nil } {
		return
	}
	close_conn(epoll_fd, conn_ptr)
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

fn process_events(mut server Server, epoll_fd int, listen_fd int) {
	mut events := [max_connection_size]C.epoll_event{}
	for {
		num_events := C.epoll_wait(epoll_fd, &events[0], max_connection_size, -1)
		for i := 0; i < num_events; i++ {
			conn_ptr := unsafe { events[i].data.ptr }

			// Check if this is the listen socket (conn_ptr will be nil for listen fd)
			if conn_ptr == unsafe { nil } {
				handle_accept_loop(epoll_fd, listen_fd, server.user_data)
				continue
			}

			mut c := unsafe { &Conn(conn_ptr) }

			if events[i].events & u32((C.EPOLLHUP | C.EPOLLERR)) != 0 {
				// Try to send 444 No Response before closing abnormal connection
				C.send(c.fd, status_444_response.data, status_444_response.len, C.MSG_NOSIGNAL)
				handle_client_closure(epoll_fd, conn_ptr)
				continue
			}

			if events[i].events & u32(C.EPOLLIN) != 0 {
				// Edge-triggered epoll: must read all available data in a loop
				mut read_error := false
				for {
					// Ensure we have space to read - grow buffer if needed
					available := c.read_buf.len - c.read_len
					if available < 4096 {
						if c.read_buf.len >= max_buf_size {
							C.send(c.fd, status_413_response.data, status_413_response.len,
								C.MSG_NOSIGNAL)
							handle_client_closure(epoll_fd, conn_ptr)
							read_error = true
							break
						}
						new_size := if c.read_buf.len * 2 > max_buf_size {
						max_buf_size
					} else {
						c.read_buf.len * 2
					}
					// Create new larger buffer and copy existing data
					mut new_buf := []u8{len: new_size, cap: new_size}
					for j := 0; j < c.read_len; j++ {
						new_buf[j] = c.read_buf[j]
					}
					c.read_buf = new_buf
				}

					// Read into connection buffer
					bytes_read := C.recv(c.fd, unsafe { &c.read_buf[c.read_len] },
						c.read_buf.len - c.read_len, 0)
					if bytes_read <= 0 {
						if bytes_read < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
							// No more data available right now
							break
						}
						if bytes_read < 0 {
							// Unexpected recv error
							C.send(c.fd, status_444_response.data, status_444_response.len,
								C.MSG_NOSIGNAL)
						}
						// bytes_read == 0 means client closed
						handle_client_closure(epoll_fd, conn_ptr)
						read_error = true
						break
					}
					c.read_len += int(bytes_read)
				}

				if read_error || c.read_len == 0 {
					continue
				}

				// Check if we have complete headers (look for \r\n\r\n)
				if !c.headers_complete {
					for j := 0; j <= c.read_len - 4; j++ {
						if c.read_buf[j] == `\r` && c.read_buf[j + 1] == `\n`
							&& c.read_buf[j + 2] == `\r` && c.read_buf[j + 3] == `\n` {
							c.headers_complete = true
							c.body_start_offset = j + 4
							// Parse Content-Length from headers
							c.content_length = parse_content_length(c.read_buf, j)
							break
						}
					}
					if !c.headers_complete {
						// Headers not complete yet, wait for more data
						continue
					}
				}

				// If we have Content-Length, check size and wait for full body
				if c.content_length > 0 {
					expected_total := c.body_start_offset + c.content_length
					if expected_total > max_buf_size {
						C.send(c.fd, status_413_response.data, status_413_response.len,
							C.MSG_NOSIGNAL)
						handle_client_closure(epoll_fd, conn_ptr)
						continue
					}
					// Grow buffer if needed
					if expected_total > c.read_buf.len {
						mut new_buf := []u8{len: expected_total, cap: expected_total}
						for j := 0; j < c.read_len; j++ {
							new_buf[j] = c.read_buf[j]
						}
						c.read_buf = new_buf
					}
					if c.read_len < expected_total {
						// Body not complete yet, wait for more data
						continue
					}
				}

				// Request is complete, process it
				mut req_buf := []u8{cap: c.read_len}
				unsafe {
					req_buf.push_many(&c.read_buf[0], c.read_len)
				}

				mut decoded_http_request := decode_http_request(req_buf) or {
					C.send(c.fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
						C.MSG_NOSIGNAL)
					handle_client_closure(epoll_fd, conn_ptr)
					continue
				}
				decoded_http_request.client_conn_fd = c.fd
				decoded_http_request.user_data = server.user_data

				response := server.request_handler(decoded_http_request) or {
					C.send(c.fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
						C.MSG_NOSIGNAL)
					handle_client_closure(epoll_fd, conn_ptr)
					continue
				}

				// Send response content (headers/body)
				if response.content.len > 0 {
					mut send_error := false
					mut pos := 0
					for pos < response.content.len {
						sent := C.send(c.fd, unsafe { &response.content[pos] },
							response.content.len - pos, C.MSG_NOSIGNAL)
						if sent <= 0 {
							send_error = true
							break
						}
						pos += sent
					}
					if send_error {
						handle_client_closure(epoll_fd, conn_ptr)
						continue
					}
				}

				// Send file if present
				if response.file_path != '' {
					fd := C.open(response.file_path.str, C.O_RDONLY)
					if fd == -1 {
						handle_client_closure(epoll_fd, conn_ptr)
						continue
					}
					mut st := C.stat{}
					if C.fstat(fd, &st) != 0 {
						C.close(fd)
						handle_client_closure(epoll_fd, conn_ptr)
						continue
					}
					mut offset := i64(0)
					mut remaining := i64(st.st_size)
					mut sf_retries := 0
					for remaining > 0 {
						ssize := C.sendfile(c.fd, fd, &offset, usize(remaining))
						if ssize > 0 {
							remaining -= i64(ssize)
							sf_retries = 0
							continue
						}
						errno_val := C.errno
						if errno_val == C.EAGAIN || errno_val == C.EWOULDBLOCK
							|| errno_val == C.EINTR {
							if sf_retries < 3 {
								sf_retries++
								continue
							}
						}
						C.close(fd)
						handle_client_closure(epoll_fd, conn_ptr)
						break
					}
					if remaining == 0 {
						C.close(fd)
					}
				}

				// Reset connection state for potential keep-alive
				c.read_len = 0
				c.headers_complete = false
				c.content_length = -1
				c.body_start_offset = 0
			}
		}
	}
}

// run starts the server and begins listening for incoming connections.
pub fn (mut server Server) run() ! {
	$if windows {
		eprintln('Windows is not supported yet')
		return
	}
	for i := 0; i < max_thread_pool_size; i++ {
		server.listen_fds[i] = create_server_socket(server.port)
		if server.listen_fds[i] < 0 {
			return
		}

		server.epoll_fds[i] = C.epoll_create1(0)
		if server.epoll_fds[i] < 0 {
			C.perror(c'epoll_create1 failed')
			close_socket(server.listen_fds[i])
			return
		}

		// Register the listening socket with each worker epoll for distributed accepts (edge-triggered)
		if add_listen_fd_to_epoll(server.epoll_fds[i], server.listen_fds[i], u32(C.EPOLLIN | C.EPOLLET)) == -1 {
			close_socket(server.listen_fds[i])
			close_socket(server.epoll_fds[i])
			return
		}

		server.threads[i] = spawn process_events(mut server, server.epoll_fds[i], server.listen_fds[i])
	}

	println('listening on http://localhost:${server.port}/')
	// Main thread waits for workers; accepts are handled in worker epoll loops
	for i in 0 .. max_thread_pool_size {
		server.threads[i].wait()
	}
}
