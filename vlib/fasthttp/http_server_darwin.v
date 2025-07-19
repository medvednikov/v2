module fasthttp

#include <sys/event.h>
#include <sys/time.h>

// C Interop - kqueue-specific functions and structs
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

// Helper to replace the C macro EV_SET
fn ev_set(mut ev &C.kevent, ident u64, filter i16, flags u16) {
	ev.ident = ident
	ev.filter = filter
	ev.flags = flags
}

// --- Darwin Implementation of Event Loop Functions ---

fn create_event_loop() int {
	kqueue_fd := C.kqueue()
	if kqueue_fd < 0 {
		C.perror(c'kqueue failed')
	}
	return kqueue_fd
}

fn add_fd_to_event_loop(kqueue_fd int, fd int) int {
	mut event := C.kevent{}
	ev_set(mut &event, u64(fd), C.EVFILT_READ, u16(C.EV_ADD))
	if C.kevent(kqueue_fd, &event, 1, C.NULL, 0, C.NULL) == -1 {
		C.perror(c'kevent add')
		return -1
	}
	return 0
}

fn remove_fd_from_event_loop(kqueue_fd int, fd int) {
	mut event := C.kevent{}
	ev_set(mut &event, u64(fd), C.EVFILT_READ, u16(C.EV_DELETE))
	C.kevent(kqueue_fd, &event, 1, C.NULL, 0, C.NULL)
}

fn process_worker_events(mut server Server, kqueue_fd int) {
	mut events := [max_connection_size]C.kevent{}
	mut connection_buffers := map[int][]u8{}

	for {
		// Passing C.NULL as the timeout makes kevent wait indefinitely.
		num_events := C.kevent(kqueue_fd, C.NULL, 0, &events[0], max_connection_size,
			C.NULL)
		if num_events < 0 {
			if C.errno == C.EINTR {
				continue
			}
			C.perror(c'kevent wait failed in worker')
			break
		}

		for i := 0; i < num_events; i++ {
			event := events[i]
			client_conn_fd := int(event.ident)

			if event.flags & u16(C.EV_EOF | C.EV_ERROR) != 0 {
				cleanup_client_connection(kqueue_fd, client_conn_fd, mut connection_buffers)
				continue
			}

			if event.filter == C.EVFILT_READ {
				// Call the shared, OS-agnostic data handler
				handle_connection_data(mut server, kqueue_fd, client_conn_fd, mut connection_buffers)
			}
		}
	}
}
