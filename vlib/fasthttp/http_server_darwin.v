// fasthttp/http_server_darwin.v
module fasthttp

#include <sys/event.h>
#include <time.h>

// --- C Interop (BSD/Darwin-specific) ---
fn C.kqueue() int
fn C.kevent(kq int, changelist &C.kevent, nchanges int, eventlist &C.kevent, nevents int, timeout &C.timespec) int

// --- C Structs (BSD/Darwin-specific) ---
struct C.timespec {
	tv_sec  i64 // time_t
	tv_nsec i64 // long
}

struct C.kevent {
	ident  u64   // identifier for this event
	filter i16   // filter for event
	flags  u16   // action flags for event
	fflags u32   // filter-specific flags
	data   i64   // filter-specific data
	udata  voidptr // opaque user data identifier
}

// --- Poller Implementation (kqueue) ---

fn poller_create() !int {
	fd := C.kqueue()
	if fd < 0 {
		return error_with_code('kqueue failed', C.errno)
	}
	return fd
}

fn poller_add_fd(poll_fd int, fd int, edge_triggered bool) ! {
	mut change := C.kevent{
		ident:  u64(fd)
		filter: C.EVFILT_READ
		flags:  u16(C.EV_ADD | C.EV_ENABLE)
	}
	if edge_triggered {
		// EV_ONESHOT is similar to EPOLLET: it triggers once and must be re-added.
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
		ident:  u64(fd)
		filter: C.EVFILT_READ
		flags:  u16(C.EV_DELETE)
	}
	// We don't check for errors on removal, as it's not critical.
	C.kevent(poll_fd, &change, 1, C.NULL, 0, C.NULL)
}

fn poller_wait(poll_fd int, mut events []Event) !int {
	mut kqueue_events := [max_connection_size]C.kevent{}
	// Wait indefinitely for an event (NULL timeout).
	num_events := C.kevent(poll_fd, C.NULL, 0, &kqueue_events[0], kqueue_events.len, C.NULL)

	if num_events < 0 {
		return error_with_code('kevent wait failed', C.errno)
	}

	for i := 0; i < num_events; i++ {
		kqueue_event := kqueue_events[i]
		events[i] = Event{
			fd: int(kqueue_event.ident)
			// Check for End-Of-File condition, which signals disconnection or error.
			is_error: (kqueue_event.flags & u16(C.EV_EOF)) != 0
		}
	}
	return num_events
}
