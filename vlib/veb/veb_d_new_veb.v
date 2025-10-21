module veb

import fasthttp

struct RequestParams {
	global_app         voidptr
	controllers_sorted []&ControllerPath
	routes             &map[string]Route
}

__global gparams RequestParams

// run_new - start a new veb server using the parallel fasthttp backend.

pub fn run_new[A, X](mut global_app A, port int) ! {
	// gapp = global_app
	if port <= 0 || port > 65535 {
		return error('invalid port number `${port}`, it should be between 1 and 65535')
	}

	// Generate routes and controllers just like the original run() function.
	routes := generate_routes[A, X](global_app)!
	controllers_sorted := check_duplicate_routes_in_controllers[A](global_app, routes)!

	gparams = &RequestParams{
		global_app:         global_app
		controllers_sorted: controllers_sorted
		routes:             &routes
		// timeout_in_seconds:
	}

	/*
	// This closure is the "glue". It will be executed in parallel by worker threads
	// for each incoming request.
	request_handler := fn [mut global_app, routes, controllers_sorted](req_bytes []u8, client_fd int) ![]u8 {
	}
	*/

	// Configure and run the vanilla_http_server.
	/*
	mut server := fasthttp.Server
	{
		port:            port
		request_handler: kek_handler[A, X]
	}
	*/
	mut server := fasthttp.new_server(port, parallel_request_handler[A, X]) or {
		eprintln('Failed to create server: ${err}')
		return
	}

	println('[veb] Running multi-threaded app on http://localhost:${port}/')
	flush_stdout()
	server.run() or { panic(err) }
}

fn parallel_request_handler[A, X](req fasthttp.HttpRequest) ![]u8 {
	// println('kek_handler')

	// println('handle_request() params.routes=${params.routes}')
	// mut global_app := unsafe { &A(params.global_app) }
	//
	// mut global_app := unsafe { &A(gapp) }
	mut global_app := unsafe { &A(gparams.global_app) }

	// println('global_app=$global_app')

	// println('params=$gparams')

	// println('req=$req')

	// println('buffer=${req.buffer.bytestr()}')
	s := req.buffer.bytestr()

	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }

	req_bytes := req.buffer
	client_fd := req.client_conn_fd

	/*

		// 1. Parse the raw request bytes into a standard `http.Request`.
		req2 := http.parse_request(req_bytes) or {
			eprintln('[veb] Failed to parse request: ${err}')
			return http_server.tiny_bad_request_response
		}
		*/

	// println('OLOO')
	req2 := http.parse_request_head_str(s) or {
		eprintln('[veb] Failed to parse request: ${err}')
		// println('s=')
		// println(s)
		return http_ok_response // http_server.tiny_bad_request_response
	}

	// println('parsed req: $req')

	// 2. Create and populate the `veb.Context`.
	completed_context := handle_request_and_route[A, X](mut global_app, req2, client_fd,
		gparams.routes, gparams.controllers_sorted)

	// 3. Serialize the final `http.Response` into a byte array.
	// Check for limitations of this synchronous backend.
	if completed_context.takeover {
		eprintln('[veb] WARNING: ctx.takeover_conn() was called, but this is not supported by this server backend. The connection will be closed after this response.')
	}

	// The vanilla_http_server expects a complete response buffer to be returned.
	return completed_context.res.bytes()

	// return  http_ok_response
}
