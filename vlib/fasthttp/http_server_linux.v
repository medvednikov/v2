module fasthttp

#include <sys/epoll.h>

// C Interop - epoll-specific functions and structs
fn C.epoll_create1(__flags int) int
fn C.epoll_ctl(__epfd int, __op int, __fd int, __event &C.epoll_event) int
fn C.epoll_wait(__epfd int, __events &C.epoll_event, __maxevents int, __timeout int) int

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

// --- Linux Implementation of Event Loop Functions ---

fn create_event_loop() int {
	epoll_fd := C.epoll_create1(0)
	if epoll_fd < 0 {
		C.perror(c'epoll_create1 failed')
	}
	return epoll_fd
}

fn add_fd_to_event_loop(epoll_fd int, fd int) int {
	mut ev := C.epoll_event{ events: u32(C.EPOLLIN) }
	ev.data.fd = fd
	if C.epoll_ctl(epoll_fd, C.EPOLL_CTL_ADD, fd, &ev) == -1 {
		C.perror(c'epoll_ctl add')
		return -1
	}
	return 0
}

fn remove_fd_from_event_loop(epoll_fd int, fd int) {
	C.epoll_ctl(epoll_fd, C.EPOLL_CTL_DEL, fd, C.NULL)
}

fn process_worker_events(mut server Server, epoll_fd int) {
	mut events := [max_connection_size]C.epoll_event{}
	mut connection_buffers := map[int][]u8{}

	for {
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

			if event.events & u32(C.EPOLLHUP | C.EPOLLERR) != 0 {
				cleanup_client_connection(epoll_fd, client_conn_fd, mut connection_buffers)
				continue
			}

			if event.events & u32(C.EPOLLIN) != 0 {
				// Call the shared, OS-agnostic data handler
				handle_connection_data(mut server, epoll_fd, client_conn_fd, mut connection_buffers)
			}
		}
	}
}
