// fasthttp/http_server_darwin.v
module fasthttp

#include <sys/event.h>
#include <time.h>

fn C.kqueue() int
fn C.kevent(kq int, changelist &C.kevent, nchanges int, eventlist &C.kevent, nevents int, timeout &C.timespec) int

struct C.timespec {
	tv_sec  i64
	tv_nsec i64
}
struct C.kevent {
	ident  u64
	filter i16
	flags  u16
	fflags u32
	data   i64
	udata  voidptr
}

fn poller_create() !int {
	fd := C.kqueue()
	if fd < 0 {
		return error_with_code('kqueue failed', C.errno)
	}
	return fd
}

fn poller_add_fd(poll_fd int, fd int, edge_triggered bool) ! {
	mut change := C.kevent{
		ident: u64(fd),
		filter: i16(C.EVFILT_READ),
		flags: u16(C.EV_ADD | C.EV_ENABLE),
	}
	if edge_triggered {
		change.flags |= u16(C.EV_ONESHOT)
	}
	ret := C.kevent(poll_fd, &change, 1, C.NULL, 0, C.NULL)
	if ret == -1 {
		return error_with_code('kevent_add failed', C.errno)
	}
	return
}

fn poller_remove_fd(poll_fd int, fd int) {
	change := C.kevent{
		ident: u64(fd),
		filter: i16(C.EVFILT_READ),
		flags: u16(C.EV_DELETE),
	}
	C.kevent(poll_fd, &change, 1, C.NULL, 0, C.NULL)
}

fn poller_wait(poll_fd int, mut events []Event) !int {
	mut kqueue_events := [max_connection_size]C.kevent{}
	num_events := C.kevent(poll_fd, C.NULL, 0, &kqueue_events[0], kqueue_events.len, C.NULL)
	if num_events < 0 {
		return error_with_code('kevent wait failed', C.errno)
	}
	for i := 0; i < num_events; i++ {
		kqueue_event := kqueue_events[i]
		events[i] = Event{
			fd: int(kqueue_event.ident),
			is_error: (kqueue_event.flags & u16(C.EV_EOF)) != 0,
		}
	}
	return num_events
}
