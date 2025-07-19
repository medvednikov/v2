// fasthttp/http_server.v
module fasthttp

import strings
import time

#include <fcntl.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h> // Needed for shutdown

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
fn C.shutdown(socket int, how int) int // For graceful shutdown

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
	fd       int
	is_error bool
}

// --- Server Definition ---
pub struct Server {
pub:
	port            int = 3000
	request_handler fn (HttpRequest) ![]u8 @[required]
mut:
	socket_fd       int
	threads         [max_thread_pool_size]thread
	new_connections [max_thread_pool_size]chan int
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
	for i := 0; i < max_thread_pool_size; i++ {
		server.new_connections[i] = chan int{cap: max_connection_size}
		server.threads[i] = spawn process_events_loop(mut server, server.new_connections[i])
	}
	println('listening on http://localhost:${server.port}/')
	server.handle_accept_loop()
}

// --- Internal Functions ---
fn close_socket(fd int) {
	C.close(fd)
}

fn create_server_socket(port int) int {
	server_fd := C.socket(.ip, .tcp, 0)
	if server_fd < 0 { C.perror(c'Socket creation failed'); return -1 }
	opt := 1
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEADDR, &opt, sizeof(opt)) < 0 {
		C.perror(c'setsockopt SO_REUSEADDR failed'); close_socket(server_fd); return -1
	}

	// FIXED: Reverted to named-field initializers for correctness and clarity.
	$if linux {
		addr := C.sockaddr_in{
			sin_family: u16(C.AF_INET)
			sin_port:   C.htons(u16(port))
			sin_addr:   u32(C.INADDR_ANY)
			sin_zero:   [8]u8{}
		}
		if C.bind(server_fd, voidptr(&addr), sizeof(addr)) < 0 {
			C.perror(c'Bind failed'); close_socket(server_fd); return -1
		}
	} $else {
		addr := C.sockaddr_in{
			sin_len:    u8(sizeof(C.sockaddr_in))
			sin_family: u8(C.AF_INET)
			sin_port:   C.htons(u16(port))
			sin_addr:   u32(C.INADDR_ANY)
			sin_zero:   [8]char{}
		}
		if C.bind(server_fd, voidptr(&addr), sizeof(addr)) < 0 {
			C.perror(c'Bind failed'); close_socket(server_fd); return -1
		}
	}

	if C.listen(server_fd, max_connection_size) < 0 {
		C.perror(c'Listen failed'); close_socket(server_fd); return -1
	}
	return server_fd
}

fn (mut server Server) handle_accept_loop() {
	for {
		client_fd := C.accept(server.socket_fd, C.NULL, C.NULL)
		if client_fd < 0 { C.perror(c'Accept failed'); return }
		server.new_connections[client_fd % max_thread_pool_size] <- client_fd
	}
}

fn handle_client_closure(poll_fd int, client_fd int) {
	poller_remove_fd(poll_fd, client_fd)
	C.shutdown(client_fd, C.SHUT_WR)
	close_socket(client_fd)
}

fn process_events_loop(mut server Server, new_conn_chan chan int) {
	poll_fd := poller_create() or {
		C.perror(c'Worker poller_create failed')
		return
	}
	mut events := [max_connection_size]Event{}
	for {
		select {
			client_fd := <-new_conn_chan {
				poller_add_fd(poll_fd, client_fd, false) or {
					eprintln('Failed to add client fd to poller: ${err}')
					close_socket(client_fd)
				}
			}
			1 * time.millisecond {
				// Timeout, proceed to check for I/O.
			}
		}

		num_events := poller_wait(poll_fd, mut events[..], 0) or { continue }
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
				readed_request_buffer := unsafe { request_buffer[..bytes_read] }
				decoded_http_request := decode_http_request(readed_request_buffer) or {
					C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
					handle_client_closure(poll_fd, client_conn_fd)
					continue
				}
				response_buffer := server.request_handler(decoded_http_request) or {
					C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
					handle_client_closure(poll_fd, client_conn_fd)
					continue
				}
				C.send(client_conn_fd, response_buffer.data, response_buffer.len, 0)
				handle_client_closure(poll_fd, client_conn_fd)
			} else {
				handle_client_closure(poll_fd, client_conn_fd)
			}
		}
	}
}
