// fasthttp/http_server.v
module fasthttp

import os

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
fn C.shutdown(socket int, how int) int
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

pub struct Event {
	fd       int
	is_error bool
}

pub struct Server {
pub:
	port            int = 3000
	request_handler fn (HttpRequest) ![]u8 @[required]
mut:
	// The threads array is only used to hold the thread handles.
	threads [max_thread_pool_size]thread
}

const tiny_bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const max_connection_size = 1024
const max_thread_pool_size = 8
const read_buffer_size = 4096

pub fn (mut server Server) run() {
	println('Starting ${max_thread_pool_size} worker threads on http://localhost:${server.port}/')

	for i := 0; i < max_thread_pool_size; i++ {
		server.threads[i] = spawn server.run_worker(i)
	}

	// CRITICAL FIX: The main thread must not block here. The worker threads
	// are independent and will keep the program alive. We let this function
	// return so the main application can continue if it needs to, or simply
	// let the OS manage the process.
	// We can use a simple sleep loop to keep the main thread alive if needed,
	// but for a dedicated server, this is often enough.
	for {
		C.sleep(1)
	}
}

// Helper to set a file descriptor to non-blocking mode.
fn set_non_blocking(fd int) ! {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags < 0 {
		return error_with_code('fcntl F_GETFL failed', C.errno)
	}
	if C.fcntl(fd, C.F_SETFL, flags | C.O_NONBLOCK) < 0 {
		return error_with_code('fcntl F_SETFL O_NONBLOCK failed', C.errno)
	}
}

fn (mut server Server) run_worker(worker_index int) {
	listening_fd := create_reusable_server_socket(server.port) or {
		eprintln('[Worker ${worker_index}] Failed to create socket: ${err}')
		return
	}
	println('[Worker ${worker_index}] Listening on FD ${listening_fd}')

	poll_fd := poller_create() or {
		eprintln('[Worker ${worker_index}] Failed to create poller: ${err}')
		os.fd_close(listening_fd)
		return
	}

	poller_add_fd(poll_fd, listening_fd, false) or {
		eprintln('[Worker ${worker_index}] Failed to add listening FD to poller: ${err}')
		os.fd_close(listening_fd)
		os.fd_close(poll_fd)
		return
	}

	mut events := [max_connection_size]Event{}
	for {
		num_events := poller_wait(poll_fd, mut events[..], -1) or { continue }

		for i := 0; i < num_events; i++ {
			event := events[i]
			if event.fd == listening_fd {
				for {
					client_fd := C.accept(listening_fd, C.NULL, C.NULL)
					if client_fd < 0 {
						if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
							break
						}
						C.perror('[Worker ${worker_index}] accept error'.str)
						break
					}
					println('[Worker ${worker_index}] Accepted new client with FD ${client_fd}')
					set_non_blocking(client_fd) or {}
					poller_add_fd(poll_fd, client_fd, false) or { os.fd_close(client_fd) }
				}
			} else {
				client_conn_fd := event.fd
				if event.is_error {
					println('[Worker ${worker_index}] Error on FD ${client_conn_fd}, closing')
					poller_remove_fd(poll_fd, client_conn_fd)
					os.fd_close(client_conn_fd)
					continue
				}

				request_buffer := [read_buffer_size]u8{}
				bytes_read := C.recv(client_conn_fd, &request_buffer[0], request_buffer.len, 0)
				println('[Worker ${worker_index}] Recv on FD ${client_conn_fd} returned ${bytes_read}')

				if bytes_read > 0 {
					readed_request_buffer := unsafe { request_buffer[..bytes_read] }
					decoded_http_request := decode_http_request(readed_request_buffer) or {
						C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
						C.shutdown(client_conn_fd, C.SHUT_WR)
						continue
					}
					response_buffer := server.request_handler(decoded_http_request) or {
						C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len, 0)
						C.shutdown(client_conn_fd, C.SHUT_WR)
						continue
					}
					C.send(client_conn_fd, response_buffer.data, response_buffer.len, 0)
					C.shutdown(client_conn_fd, C.SHUT_WR)
				} else {
					println('[Worker ${worker_index}] EOF/error on FD ${client_conn_fd}, closing')
					poller_remove_fd(poll_fd, client_conn_fd)
					os.fd_close(client_conn_fd)
				}
			}
		}
	}
}

fn create_reusable_server_socket(port int) !int {
	server_fd := C.socket(.ip, .tcp, 0)
	if server_fd < 0 {
		return error_with_code('Socket creation failed', C.errno)
	}

	opt := 1
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEPORT, &opt, sizeof(opt)) < 0 {
		os.fd_close(server_fd)
		return error_with_code('setsockopt SO_REUSEPORT failed', C.errno)
	}

	set_non_blocking(server_fd) or {
		os.fd_close(server_fd)
		return err
	}

	$if linux {
		addr := C.sockaddr_in{
			sin_family: u16(C.AF_INET)
			sin_port:   C.htons(u16(port))
			sin_addr:   u32(C.INADDR_ANY)
			sin_zero:   [8]u8{}
		}
		if C.bind(server_fd, voidptr(&addr), sizeof(addr)) < 0 {
			os.fd_close(server_fd)
			return error_with_code('Bind failed', C.errno)
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
			os.fd_close(server_fd)
			return error_with_code('Bind failed', C.errno)
		}
	}
	if C.listen(server_fd, max_connection_size) < 0 {
		os.fd_close(server_fd)
		return error_with_code('Listen failed', C.errno)
	}
	return server_fd
}
