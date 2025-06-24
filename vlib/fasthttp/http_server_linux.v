// fasthttp/http_server_linux.v
module fasthttp

#include <sys/epoll.h>

fn C.epoll_create1(__flags int) int
fn C.epoll_ctl(__epfd int, __op int, __fd int, __event &C.epoll_event) int
fn C.epoll_wait(__epfd int, __events &C.epoll_event, __maxevents int, __timeout int) int

union C.epoll_data { ptr voidptr; fd int; u32 u32; u64 u64; }
struct C.epoll_event { events u32; data C.epoll_data; }

fn poller_create() !int {
	fd := C.epoll_create1(0)
	if fd < 0 { return error_with_code('epoll_create1 failed', C.errno) }
	return fd
}
fn poller_add_fd(poll_fd int, fd int, edge_triggered bool) ! {
	mut ev := C.epoll_event{ events: u32(C.EPOLLIN) }
	if edge_triggered { ev.events |= u32(C.EPOLLET) }
	ev.data.fd = fd
	if C.epoll_ctl(poll_fd, C.EPOLL_CTL_ADD, fd, &ev) == -1 {
		return error_with_code('epoll_ctl_add failed', C.errno)
	}
}
fn poller_remove_fd(poll_fd int, fd int) {
	C.epoll_ctl(poll_fd, C.EPOLL_CTL_DEL, fd, C.NULL)
}

// FIXED: Now accepts a timeout parameter.
fn poller_wait(poll_fd int, mut events []Event, timeout_ms int) !int {
	mut epoll_events := [max_connection_size]C.epoll_event{}
	num_events := C.epoll_wait(poll_fd, &epoll_events[0], epoll_events.len, timeout_ms)
	if num_events < 0 { return error_with_code('epoll_wait failed', C.errno) }
	for i := 0; i < num_events; i++ {
		epoll_event := epoll_events[i]
		events[i] = Event{
			fd: epoll_event.data.fd,
			is_error: (epoll_event.events & u32(C.EPOLLERR | C.EPOLLHUP)) != 0,
		}
	}
	return num_events
}
