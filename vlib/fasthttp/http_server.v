// fasthttp/http_server.v
module fasthttp

import net

// C Interop - POSIX functions common to both Linux and macOS
#include <fcntl.h>
#include <errno.h>
#include <netinet/in.h>

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

// Server struct is now completely OS-agnostic.
// `event_fds` holds the file descriptor for either epoll or kqueue.
pub struct Server {
pub:
	port            int = 3000
	request_handler fn (HttpRequest) ![]u8 @[required]
mut:
	socket_fd int
	event_fds [max_thread_pool_size]int
	threads   [max_thread_pool_size]thread
}

// Constants
const tiny_bad_request_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const max_connection_size = 1024
const max_thread_pool_size = 8
const read_buffer_size = 4096

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

	// Create a dedicated event loop for each worker thread and spawn it.
	// The V compiler will call the correct OS-specific implementation.
	for i := 0; i < max_thread_pool_size; i++ {
		server.event_fds[i] = create_event_loop()
		if server.event_fds[i] < 0 {
			// In a real app, tear down previously created resources.
			return
		}
		server.threads[i] = spawn process_worker_events(mut server, server.event_fds[i])
	}

	println('listening on http://localhost:${server.port}/')
	server.handle_accept_loop()
}

// --- High-Level Internal Functions ---

fn (mut server Server) handle_accept_loop() {
	mut next_worker := 0
	for {
		client_conn_fd := C.accept(server.socket_fd, C.NULL, C.NULL)
		if client_conn_fd < 0 {
			C.perror(c'Accept failed')
			continue
		}

		set_blocking(client_conn_fd, false)

		worker_event_fd := server.event_fds[next_worker]
		next_worker = (next_worker + 1) % max_thread_pool_size

		if add_fd_to_event_loop(worker_event_fd, client_conn_fd) < 0 {
			eprintln('Failed to add client fd ${client_conn_fd} to worker. Closing socket.')
			close_socket(client_conn_fd)
		}
	}
}

// Contains the shared logic for reading and responding to a request.
// It's called by the OS-specific `process_worker_events` function.
fn handle_connection_data(mut server Server, event_fd int, client_conn_fd int, mut connection_buffers map[int][]u8) {
	mut client_closed_connection := false

	if client_conn_fd !in connection_buffers {
		connection_buffers[client_conn_fd] = []u8{}
	}

	// Loop to read all available data from the socket.
	for {
		mut read_buf := [read_buffer_size]u8{}
		bytes_read := C.recv(client_conn_fd, &read_buf[0], read_buffer_size, 0)

		if bytes_read > 0 {
			connection_buffers[client_conn_fd].push_many(&read_buf[0], bytes_read)
		} else if bytes_read == 0 {
			client_closed_connection = true
			break
		} else { // bytes_read < 0
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				break // No more data to read right now.
			}
			C.perror(c'recv failed')
			client_closed_connection = true
			break
		}
	}

	request_buffer := connection_buffers[client_conn_fd]

	if request_buffer.len > 0 || client_closed_connection {
		if request_buffer.len == 0 && client_closed_connection {
			cleanup_client_connection(event_fd, client_conn_fd, mut connection_buffers)
			return
		}

		// Decode, handle, and respond to the request.
		mut decoded_http_request := decode_http_request(request_buffer) or {
			eprintln('Error decoding request: ${err}')
			C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
				0)
			cleanup_client_connection(event_fd, client_conn_fd, mut connection_buffers)
			return
		}

		decoded_http_request.client_conn_fd = client_conn_fd
		response_buffer := server.request_handler(decoded_http_request) or {
			eprintln('Error handling request: ${err}')
			C.send(client_conn_fd, tiny_bad_request_response.data, tiny_bad_request_response.len,
				0)
			cleanup_client_connection(event_fd, client_conn_fd, mut connection_buffers)
			return
		}

		C.send(client_conn_fd, response_buffer.data, response_buffer.len, 0)
		cleanup_client_connection(event_fd, client_conn_fd, mut connection_buffers)
	}
}

// --- Utility Functions ---

fn create_server_socket(port int) int {
	server_fd := C.socket(.ip, .tcp, 0)
	if server_fd < 0 {
		C.perror(c'Socket creation failed')
		return -1
	}

	opt := 1
	if C.setsockopt(server_fd, C.SOL_SOCKET, C.SO_REUSEPORT, &opt, sizeof(opt)) < 0 {
		C.perror(c'setsockopt SO_REUSEPORT failed')
		close_socket(server_fd)
		return -1
	}

	server_addr := C.sockaddr_in{
		sin_family: C.AF_INET
		sin_port:   C.htons(u16(port))
		sin_addr:   u32(C.INADDR_ANY)
	}

	if C.bind(server_fd, voidptr(&server_addr), sizeof(server_addr)) < 0 {
		C.perror(c'Bind failed')
		close_socket(server_fd)
		return -1
	}

	if C.listen(server_fd, max_connection_size) < 0 {
		C.perror(c'Listen failed')
		close_socket(server_fd)
		return -1
	}
	return server_fd
}

fn set_blocking(fd int, blocking bool) {
	flags := C.fcntl(fd, C.F_GETFL, 0)
	if flags == -1 {
		C.perror(c'fcntl F_GETFL')
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

fn cleanup_client_connection(event_fd int, client_fd int, mut buffers map[int][]u8) {
	remove_fd_from_event_loop(event_fd, client_fd)
	close_socket(client_fd)
	buffers.delete(client_fd)
}
