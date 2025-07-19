// fasthttp/http_server.v
module fasthttp

import time
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
fn C.fcntl(fd int, cmd int, arg int) int
fn C.shutdown(socket int, how int) int
fn C.pipe(fds &int) int
fn C.read(fd int, buf voidptr, n u64) int
fn C.write(fd int, buf voidptr, n u64) int

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
	socket_fd         int
	threads           [max_thread_pool_size]thread
	new_connections   [max_thread_pool_size]chan int
	wakeup_pipe_fds   [max_thread_pool_size][2]int
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
		if C.pipe(&server.wakeup_pipe_fds[i][0]) != 0 {
			C.perror(c'Pipe creation failed')
			return
		}
		server.threads[i] = spawn process_events_loop(i, mut server, server.new_connections[i], server.wakeup_pipe_fds[i][0])
	}
	println('listening on http://localhost:${server.port}/')
	server.handle_accept_loop()
}

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
		addr := C.sockaddr_in{
			sin_family: u16(C.AF_INET)
			sin_port:   C.htons(u16(port))
			sin_addr:   u32(C.INADDR_ANY)
			sin_zero:   [8]u8{}
		}
		if C.bind(server_fd, voidptr(&addr), sizeof(addr)) < 0 {
			C.perror(c'Bind failed')
			close_socket(server_fd)
			return -1
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
			return
		}

		worker_index := client_fd % max_thread_pool_size
		println('[Main] Accepted client FD ${client_fd}, dispatching to worker ${worker_index}')
		server.new_connections[worker_index] <- client_fd
		C.write(server.wakeup_pipe_fds[worker_index][1], c'w', 1)
	}
}

fn process_events_loop(worker_index int, mut server Server, new_conn_chan chan int, pipe_read_fd int) {
	poll_fd := poller_create() or { C.perror(c'Worker poller_create failed'); return }
	poller_add_fd(poll_fd, pipe_read_fd, false) or { return }

	mut events := [max_connection_size]Event{}
	for {
		num_events := poller_wait(poll_fd, mut events[..], -1) or { continue }
		println('[Worker ${worker_index}] Poller woke up with ${num_events} events')

		for i := 0; i < num_events; i++ {
			event := events[i]
			if event.fd == pipe_read_fd {
				println('[Worker ${worker_index}] Woke up for pipe signal')
				mut temp_buf := [1]u8{}
				C.read(pipe_read_fd, &temp_buf[0], 1)
				for {
					select {
						new_client_fd := <-new_conn_chan {
							println('[Worker ${worker_index}] Got new client FD ${new_client_fd} from channel')
							poller_add_fd(poll_fd, new_client_fd, false) or {
								eprintln('[Worker ${worker_index}] Failed to add FD ${new_client_fd}')
								os.fd_close(new_client_fd)
							}
						}
					else {
						break
					}
					}
				}
				continue
			}

			client_conn_fd := event.fd
			if event.is_error {
				println('[Worker ${worker_index}] Error on FD ${client_conn_fd}, closing')
				poller_remove_fd(poll_fd, client_conn_fd)
				os.fd_close(client_conn_fd)
				continue
			}

			request_buffer := [read_buffer_size]u8{}
			bytes_read := C.recv(client_conn_fd, &request_buffer[0], request_buffer.len - 1, 0)
			println('[Worker ${worker_index}] Recv on FD ${client_conn_fd} returned ${bytes_read}')

			if bytes_read > 0 {
				readed_request_buffer := unsafe { request_buffer[..bytes_read] }
				println('[Worker ${worker_index}] Read ${bytes_read} bytes from FD ${client_conn_fd}')
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
				println('[Worker ${worker_index}] Sent response to FD ${client_conn_fd}, shutting down WR')
				C.shutdown(client_conn_fd, C.SHUT_WR)
			} else {
				println('[Worker ${worker_index}] Received EOF/error for FD ${client_conn_fd}, closing')
				poller_remove_fd(poll_fd, client_conn_fd)
				os.fd_close(client_conn_fd)
			}
		}
	}
}
