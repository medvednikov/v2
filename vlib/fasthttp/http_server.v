// fasthttp/http_server.v
module fasthttp

import strings

#include <fcntl.h>
#include <errno.h>
#include <netinet/in.h>

// --- C Interop (Common POSIX) ---
fn C.bind(sockfd int, addr &C.sockaddr_in, addrlen u32) int
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.setsockopt(__fd int, __level int, __optname int, __optval voidptr, __optlen u32) int
fn C.listen(__fd int, __n int) int
fn C.perror(s &u8)
fn C.close(fd int) int
fn C.accept(sockfd int, address &C.sockaddr_in, addrlen &u32) int
fn C.htons(__hostshort u16) u16
fn C.fcntl(fd int, cmd int, arg int) int

// --- C Structs (Platform-specific) ---
$if linux {
	struct C.sockaddr_in {
		sin_family u16
		sin_port   u16
		sin_addr   u32
		sin_zero   [8]u8
	}
} $else {
	struct C.sockaddr_in {
		sin_len    u8
		sin_family u8
		sin_port   u16
		sin_addr   u32
		sin_zero   [8]char
	}
}

// --- Platform Abstraction ---
pub struct Event {
pub:
	fd       int
	is_error bool
}

// --- Server Definition ---
pub struct Server {
pub:
	port            int = 3000
	request_handler fn (HttpRequest) ![]u8 @[required]
mut:
	socket_fd int
	poll_fds  [max_thread_pool_size]int
	threads   [max_thread_pool_size]thread
}

const tiny_bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const max_connection_size = 1024
const max_thread_pool_size = 8
const read_buffer_size = 4096

pub fn (mut server Server) run() {
	server.socket_fd = create_server_socket(server.port)
	if server.socket_fd < 0 {
		return
	}

	// Create a poller instance for each worker thread.
	// We DO NOT add the listening socket to these worker pollers.
	for i := 0; i < max_thread_pool_size; i++ {
		server.poll_fds[i] = poller_create() or {
			C.perror(c'poller_create failed')
			close_socket(server.socket_fd)
			return
		}
		// Spawn a worker thread to process events for its poller.
		server.threads[i] = spawn process_events(mut server, server.poll_fds[i])
	}

	println('listening on http://localhost:${server.port}/')
	// The main thread's only job is to accept new connections and
	// distribute them to the worker threads.
	server.handle_accept_loop()
}

// --- Internal Functions ---
fn close_socket(fd int) {
	C.close(fd)
}

fn create_server_socket(port int) int {
	server_fd := C.socket(.ip, .tcp, 0)
	if server_fd < 0 {
		C.perror(c'Socket creation failed')
		return -1
	}
	opt := 1
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(opt)) < 0 {
		C.perror(c'setsockopt SO_REUSEADDR failed')
		close_socket(server_fd)
		return -1
	}
	$if linux {
		server_addr := C.sockaddr_in{
			sin_family: u16(C.AF_INET),
			sin_port: C.htons(u16(port)),
			sin_addr: u32(C.INADDR_ANY),
			sin_zero: [8]u8{},
		}
		if C.bind(server_fd, voidptr(&server_addr), sizeof(server_addr)) < 0 {
			C.perror(c'Bind failed')
			close_socket(server_fd)
			return -1
		}
	} $else {
		mut server_addr := C.sockaddr_in{
			sin_family: u8(C.AF_INET),
			sin_port: C.htons(u16(port)),
			sin_addr: u32(C.INADDR_ANY),
			sin_zero: [8]char{},
		}
		server_addr.sin_len = u8(sizeof(server_addr))
		if C.bind(server_fd, voidptr(&server_addr), sizeof(server_addr)) < 0 {
			C.perror(c'Bind failed')
			close_socket(server_fd)
			return -1
		}
	}
	if C.listen(server_fd, max_connection_size) < 0 {
		C.perror(c'Listen failed')
		close_socket(server_fd)
		return -1
	}
	return server_fd
}

fn (mut server Server) handle_accept_loop() {
	for {
		client_fd := C.accept(server.socket_fd, C.NULL, C.NULL)
		if client_fd < 0 {
			C.perror(c'Accept failed')
			return // Stop the loop on accept error
		}
		// Distribute the new client FD to a worker using round-robin
		poll_fd := server.poll_fds[client_fd % max_thread_pool_size]

		// Use level-triggering (`edge_triggered: false`). It's simpler and robust.
		poller_add_fd(poll_fd, client_fd, false) or {
			eprintln('Failed to add client fd to poller: ${err}')
			close_socket(client_fd)
		}
	}
}

fn handle_client_closure(poll_fd int, client_fd int) {
	poller_remove_fd(poll_fd, client_fd)
	close_socket(client_fd)
}

// This function runs in the worker threads.
// It uses a simple, single-read logic suitable for level-triggered polling.
fn process_events(mut server Server, poll_fd int) {
	mut events := [max_connection_size]Event{}
	for {
		num_events := poller_wait(poll_fd, mut events[..]) or {
			eprintln('poller_wait error: ${err}')
			continue
		}
		for i := 0; i < num_events; i++ {
			event := events[i]
			client_conn_fd := event.fd

			if event.is_error {
				handle_client_closure(poll_fd, client_conn_fd)
				continue
			}

			request_buffer := [read_buffer_size]u8{}
			bytes_read := C.recv(client_conn_fd, &request_buffer[0], request_buffer.len - 1, 0)

			if bytes_read > 0 {
				mut readed_request_buffer := []u8{cap: bytes_read}
				unsafe {
					readed_request_buffer.push_many(&request_buffer[0], bytes_read)
				}
				mut decoded_http_request := decode_http_request(readed_request_buffer) or {
					C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
					handle_client_closure(poll_fd, client_conn_fd)
					continue
				}
				decoded_http_request.client_conn_fd = client_conn_fd

				response_buffer := server.request_handler(decoded_http_request) or {
					C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
					handle_client_closure(poll_fd, client_conn_fd)
					continue
				}
				C.send(client_conn_fd, response_buffer.data, response_buffer.len, 0)
				handle_client_closure(poll_fd, client_conn_fd)
			} else {
				// bytes_read == 0 (client closed) or < 0 (real error).
				handle_client_closure(poll_fd, client_conn_fd)
			}
		}
	}
}
