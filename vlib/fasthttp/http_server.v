// fasthttp/http_server.v
module fasthttp

#include <fcntl.h>
#include <errno.h>

$if !windows {
	#include <sys/epoll.h>
	#include <netinet/in.h>
}

// C Interop - Identical to original
// fn C.socket(socket_family int, socket_type int, protocol int) int
fn C.bind(sockfd int, addr &C.sockaddr_in, addrlen u32) int
fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.setsockopt(__fd int, __level int, __optname int, __optval voidptr, __optlen u32) int
fn C.listen(__fd int, __n int) int
fn C.perror(s &u8)
fn C.close(fd int) int
fn C.accept(sockfd int, address &C.sockaddr_in, addrlen &u32) int
fn C.htons(__hostshort u16) u16
fn C.epoll_create1(__flags int) int
fn C.epoll_ctl(__epfd int, __op int, __fd int, __event &C.epoll_event) int
fn C.epoll_wait(__epfd int, __events &C.epoll_event, __maxevents int, __timeout int) int
fn C.fcntl(fd int, cmd int, arg int) int

// C Structs - Identical to original formatting
struct C.in_addr {
	s_addr u32
}

struct C.sockaddr_in {
	sin_family u16
	sin_port   u16
	sin_addr   u32 // C.in_addr
	sin_zero   [8]u8
}

union C.epoll_data {
	ptr voidptr
	fd  int
	u32 u32
	u64 u64
}

struct C.epoll_event {
	events u32
	data   C.epoll_data
}

pub struct Server {
pub:
	port            int = 3000
	request_handler fn (HttpRequest) ![]u8 @[required]
mut:
	socket_fd int
	epoll_fds [max_thread_pool_size]int
	threads   [max_thread_pool_size]thread
}

const tiny_bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const max_connection_size = 1024
const max_thread_pool_size = 8

// --- Server Entry Point ---
pub fn (mut server Server) run() {
	$if windows {
		eprintln('Windows is not supported yet')
		return
	}

	server.socket_fd = create_server_socket(server.port)
	if server.socket_fd < 0 {
		return
	}

	// Create a dedicated epoll instance for each worker thread and spawn it.
	for i := 0; i < max_thread_pool_size; i++ {
		server.epoll_fds[i] = C.epoll_create1(0)
		if server.epoll_fds[i] < 0 {
			C.perror('epoll_create1 failed for worker ${i}')
			// In a real app, you would tear down previously created resources.
			return
		}
		// Each worker thread processes events on its own epoll instance.
		server.threads[i] = spawn process_worker_events(mut server, server.epoll_fds[i])
	}

	println('listening on http://localhost:${server.port}/')
	// The main thread's only job is now to accept connections.
	server.handle_accept_loop()
}

// --- Internal Functions (copied verbatim from original) ---

fn set_blocking(fd int, blocking bool) {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags == -1 {
		eprintln(@LOCATION)
		return
	}
	if blocking {
		C.fcntl(fd, C.F_SETFL, flags & ~C.O_NONBLOCK)
	} else {
		C.fcntl(fd, C.F_SETFL, flags | C.O_NONBLOCK)
	}
}

fn close_socket(fd int) {
	C.close(fd)
}

fn create_server_socket(port int) int {
	server_fd := C.socket(.ip, .tcp, 0)
	if server_fd < 0 {
		eprintln(@LOCATION)
		C.perror(c'Socket creation failed')
		return -1
	}
	// set_blocking(server_fd, false)
	opt := 1
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEPORT, &opt, sizeof(opt)) < 0 {
		eprintln(@LOCATION)
		C.perror(c'setsockopt SO_REUSEPORT failed')
		close_socket(server_fd)
		return -1
	}
	server_addr := C.sockaddr_in{
		sin_family: u16(C.AF_INET)
		sin_port:   C.htons(u16(port))
		sin_addr:   u32(C.INADDR_ANY)
		sin_zero:   [8]u8{}
	}
	if C.bind(server_fd, voidptr(&server_addr), sizeof(server_addr)) < 0 {
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

fn add_fd_to_epoll(epoll_fd int, fd int, events u32) int {
	mut ev := C.epoll_event{
		events: events
	}
	ev.data.fd = fd
	if C.epoll_ctl(epoll_fd, C.EPOLL_CTL_ADD, fd, &ev) == -1 {
		eprintln(@LOCATION)
		C.perror(c'epoll_ctl')
		return -1
	}
	return 0
}

fn remove_fd_from_epoll(epoll_fd int, fd int) {
	C.epoll_ctl(epoll_fd, C.EPOLL_CTL_DEL, fd, C.NULL)
}

// handle_accept_loop is run by the MAIN thread.
// Its only job is to accept new connections and distribute them to the worker threads.
fn (mut server Server) handle_accept_loop() {
	mut next_worker := 0
	for {
		client_conn_fd := C.accept(server.socket_fd, C.NULL, C.NULL)
		if client_conn_fd < 0 {
			// This can happen on server shutdown.
			C.perror(c'Accept failed')
			continue
		}

		// Set the new client socket to non-blocking for epoll.
		set_blocking(client_conn_fd, false)

		// Distribute the new connection to a worker thread via round-robin.
		worker_epoll_fd := server.epoll_fds[next_worker]
		next_worker = (next_worker + 1) % max_thread_pool_size

		// Add the client to the chosen worker's epoll set.
		if add_fd_to_epoll(worker_epoll_fd, client_conn_fd, u32(C.EPOLLIN | C.EPOLLET)) < 0 {
			close_socket(client_conn_fd)
		}
	}
}

// NOTE: This function is copied verbatim from the original code as requested.
// The original logic `remove_fd_from_epoll(client_fd, client_fd)` is incorrect,
// as the first argument should be the epoll instance file descriptor.
// This version is preserved for fidelity to the original code.
fn handle_client_closure(server &Server, client_fd int) {
	unsafe {
		remove_fd_from_epoll(client_fd, client_fd)
	}
}

// process_worker_events is run by each WORKER thread.
// Its job is to handle reading/writing for the connections it has been assigned.
fn process_worker_events(mut server Server, epoll_fd int) {
	mut events := [max_connection_size]C.epoll_event{}
	// Each worker manages its own set of connection buffers.
	mut connection_buffers := map[int][]u8{}

	for {
		// This worker waits for events ONLY on its own epoll instance.
		num_events := C.epoll_wait(epoll_fd, &events[0], max_connection_size, -1)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'epoll_wait failed in worker')
			break
		}

		for i := 0; i < num_events; i++ {
			event := events[i]
			client_conn_fd := unsafe { event.data.fd }

			// Check for errors or hang-ups.
			if event.events & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				cleanup_client_connection(epoll_fd, client_conn_fd, mut connection_buffers)
				continue
			}

			// The socket has data to be read.
			if event.events & u32(C.EPOLLIN) != 0 {
				// --- CRITICAL FIX: Read in a loop for Edge-Triggered mode ---
				for {
					mut read_buf := [read_buffer_size]u8{}
					bytes_read := C.recv(client_conn_fd, &read_buf[0], read_buffer_size,
						0)

					if bytes_read > 0 {
						// Append the newly read data to this connection's buffer.
						connection_buffers[client_conn_fd].push_many(&read_buf[0], bytes_read)
					} else if bytes_read == 0 {
						// Client closed the connection cleanly.
						// The request will be processed, and then the connection closed.
						break
					} else {
						// bytes_read < 0
						if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
							// We have read all available data from the socket buffer.
							// This is the normal exit from a successful read loop.
							break
						} else {
							// A real read error occurred.
							C.perror(c'recv failed')
							cleanup_client_connection(epoll_fd, client_conn_fd, mut connection_buffers)
							break // Stop trying to read from this broken socket.
						}
					}
				} // End of the non-blocking read loop.

				// --- Process the fully read request ---
				request_buffer := connection_buffers[client_conn_fd]
				if request_buffer.len == 0 {
					// This can happen if the client connects and disconnects without sending data.
					cleanup_client_connection(epoll_fd, client_conn_fd, mut connection_buffers)
					continue
				}

				mut decoded_http_request := decode_http_request(request_buffer) or {
					eprintln('Error decoding request: ${err}')
					C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
						0)
					cleanup_client_connection(epoll_fd, client_conn_fd, mut connection_buffers)
					continue
				}

				decoded_http_request.client_conn_fd = client_conn_fd
				response_buffer := server.request_handler(decoded_http_request) or {
					eprintln('Error handling request: ${err}')
					C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
						0)
					cleanup_client_connection(epoll_fd, client_conn_fd, mut connection_buffers)
					continue
				}

				C.send(client_conn_fd, response_buffer.data, response_buffer.len, 0)
				// Request is handled, now clean up.
				cleanup_client_connection(epoll_fd, client_conn_fd, mut connection_buffers)
			}
		}
	}
}

fn process_events(mut server Server, main_epoll_fd int) {
	println('handle_accept_loop()')
	mut next_worker := 0
	mut event := C.epoll_event{}

	for {
		println('FOR')
		num_events := C.epoll_wait(main_epoll_fd, &event, 1, -1)
		println('num_events=${num_events}')
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'epoll_wait')
			break
		}

		if num_events > 1 {
			eprintln('More than one event in epoll_wait, this should not happen.')
			continue
		}

		if event.events & u32(C.EPOLLIN) != 0 {
			for {
				client_conn_fd := C.accept(server.socket_fd, C.NULL, C.NULL)
				if client_conn_fd < 0 {
					// Check for EAGAIN or EWOULDBLOCK, usually represented by errno 11.
					if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
						break // No more incoming connections; exit loop.
					}
					eprintln(@LOCATION)
					C.perror(c'Accept failed')
					continue
				}
				set_blocking(client_conn_fd, false)
				// Load balance the client connection to the worker threads.
				// this is a simple round-robin approach.
				epoll_fd := server.epoll_fds[next_worker]
				next_worker = (next_worker + 1) % max_thread_pool_size
				if add_fd_to_epoll(epoll_fd, client_conn_fd, u32(C.EPOLLIN | C.EPOLLET)) < 0 {
					close_socket(client_conn_fd)
					continue
				}
			}
		}
	}
}

fn process_events_old(mut server Server, epoll_fd int) {
	for {
		events := [max_connection_size]C.epoll_event{}
		num_events := C.epoll_wait(epoll_fd, &events[0], max_connection_size, -1)
		for i := 0; i < num_events; i++ {
			client_conn_fd := unsafe { events[i].data.fd }
			if events[i].events & u32((C.EPOLLHUP | C.EPOLLERR)) != 0 {
				handle_client_closure(server, client_conn_fd)
				continue
			}
			if events[i].events & u32(C.EPOLLIN) != 0 {
				request_buffer := [140]u8{}
				bytes_read := C.recv(client_conn_fd, &request_buffer[0], 140 - 1, 0)
				if bytes_read > 0 {
					mut readed_request_buffer := []u8{cap: bytes_read}
					unsafe {
						readed_request_buffer.push_many(&request_buffer[0], bytes_read)
					}
					println('readed_request_buffer: ${readed_request_buffer}')
					mut decoded_http_request := decode_http_request(readed_request_buffer) or {
						eprintln('Error decoding request ${err}')
						C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
							0)
						handle_client_closure(server, client_conn_fd)
						continue
					}
					println('AZAZA DECODED HTTP REQUEST ${decoded_http_request}')
					println('=============')
					println(decoded_http_request.buffer.bytestr())
					println('END')
					decoded_http_request.client_conn_fd = client_conn_fd
					response_buffer := server.request_handler(decoded_http_request) or {
						eprintln('Error handling request ${err}')
						C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
							0)
						handle_client_closure(server, client_conn_fd)
						continue
					}
					C.send(client_conn_fd, response_buffer.data, response_buffer.len,
						0)
					handle_client_closure(server, client_conn_fd)
				} else if bytes_read == 0
					|| (bytes_read < 0 && C.errno != C.EAGAIN && C.errno != C.EWOULDBLOCK) {
					handle_client_closure(server, client_conn_fd)
				}
			}
		}
	}
}
