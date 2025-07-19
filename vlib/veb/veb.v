// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
//
// This version is refactored to use `vanilla_http_server` exclusively.
module veb

// import vanilla_http_server.http_server
// import vanilla_http_server.request_parser
import fasthttp
import net
import net.http
import net.urllib
import os
import time
import strings

// A type which doesn't get filtered inside templates
pub type RawHtml = string

// A dummy structure that returns from routes to indicate that you actually sent something to a user
@[noinit]
pub struct Result {}

// no_result does nothing, but returns `veb.Result`. Only use it when you are sure
// a response will be sent over the connection, or in combination with `Context.takeoverP0+r\P0+r\P0+r\P0+r\P0+r\_conn`
pub fn no_result() Result {
	return Result{}
}

struct Route {
	methods []http.Method
	path    string
	host    string
mut:
	middlewares       []voidptr
	after_middlewares []voidptr
}

struct RequestParams {
	global_app         voidptr
	controllers_sorted []&ControllerPath
	routes             &map[string]Route
	/*
	timeout_in_seconds int
mut:
	// request body buffer
	buf &u8 = unsafe { nil }
	// idx keeps track of how much of the request body has been read
	// for each incomplete request, see `handle_conn`
	idx                 []int
	incomplete_requests []http.Request
	file_responses      []FileResponse
	string_responses    []StringResponse
	*/
}

// run - start a new veb server using the parallel vanilla_http_server backend.
pub fn run[A, X](mut global_app A, port int) ! {
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
	mut server := fasthttp.Server{
		port:            port
		request_handler: kek_handler[A, X]
	}
	println('[veb] Running multi-threaded app on http://localhost:${port}/')
	flush_stdout()
	server.run()
}

//__global gapp voidptr
__global gparams RequestParams

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn kek_handler[A, X](req fasthttp.HttpRequest) ![]u8 {
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

// handle_request_and_route is a unified function that creates the context,
// runs middleware, and finds the correct route for a request.
fn handle_request_and_route[A, X](mut app A, req http.Request, client_fd int, routes &map[string]Route, controllers []&ControllerPath) &Context {
	// Create a `net.TcpConn` from the file descriptor for context compatibility.
	mut conn := &net.TcpConn{
		sock:        net.tcp_socket_from_handle_raw(client_fd)
		handle:      client_fd
		is_blocking: false // vanilla_http_server ensures this
	}

	// Create and populate the `veb.Context` from the request.
	mut url := urllib.parse(req.url) or {
		// This should be rare if http.parse_request succeeded.
		mut bad_ctx := &Context{
			req:  req
			conn: conn
		}
		bad_ctx.not_found()
		return bad_ctx
	}
	query := parse_query_from_url(url)
	form, files := parse_form_from_request(req) or {
		mut bad_ctx := &Context{
			req:  req
			conn: conn
		}
		bad_ctx.request_error('Failed to parse form data: ${err.msg()}')
		return bad_ctx
	}
	host_with_port := req.header.get(.host) or { '' }
	host, _ := urllib.split_host_port(host_with_port)

	mut ctx := &Context{
		req:            req
		page_gen_start: time.ticks()
		conn:           conn
		query:          query
		form:           form
		files:          files
	}

	if connection_header := req.header.get(.connection) {
		if connection_header.to_lower() == 'close' {
			ctx.client_wants_to_close = true
		}
	}

	$if A is StaticApp {
		ctx.custom_mime_types = app.static_mime_types.clone()
	}

	// Match controller paths first
	$if A is ControllerInterface {
		if completed_context := handle_controllers[X](controllers, ctx, mut url, host) {
			return completed_context
		}
	}

	// Create a new user context and pass veb's context
	mut user_context := X{}
	user_context.Context = ctx

	handle_route[A, X](mut app, mut user_context, url, host, routes)
	return &user_context.Context
}

// handle_route finds and executes the correct handler for a given URL.
// This is adapted from the original `veb` but with simplified cleanup.
fn handle_route[A, X](mut app A, mut user_context X, url urllib.URL, host string, routes &map[string]Route) {
	////println('handle_route() url=$url host=$host')
	// println('AZAZA routes=$routes')
	mut route := Route{}
	mut middleware_has_sent_response := false
	mut not_found := false

	defer {
		// After-middleware logic
		if !not_found && !middleware_has_sent_response {
			was_done := user_context.Context.done
			user_context.Context.done = false
			$if A is MiddlewareApp {
				validate_middleware[X](mut user_context, app.Middleware.get_global_handlers_after[X]())
				validate_middleware[X](mut user_context, route.after_middlewares)
			}
			// println('user_context2=${user_context} was_done=${was_done}')
			if !was_done && !user_context.Context.done {
				eprintln('[veb] handler for route "${url.path}" does not send any data! LOL')
				user_context.server_error('Handler did not produce a response.')
			}
		}
	}

	url_words := url.path.split('/').filter(it != '')

	$if A is HasBeforeRequest {
		app.before_request()
	}
	if user_context.Context.done {
		return
	}

	$if A is MiddlewareApp {
		if !validate_middleware[X](mut user_context, app.Middleware.get_global_handlers[X]()) {
			middleware_has_sent_response = true
			return
		}
	}

	$if A is StaticApp {
		if serve_if_static[A, X](app, mut user_context, url, host) {
			return
		}
	}

	// Route matching logic (identical to original)
	// println("FINDING ROUTE")
	$for method in A.methods {
		// println('method $method.name')
		$if method.return_type is Result {
			route = (*routes)[method.name] or { return }
			if user_context.Context.req.method in route.methods {
				route_words := route.path.split('/').filter(it != '')
				if route.host == '' || route.host == host {
					can_have_data_args := user_context.Context.req.method in methods_with_form
					if !route.path.contains('/:') && url_words == route_words {
						if !validate_middleware[X](mut user_context, route.middlewares) {
							middleware_has_sent_response = true
							return
						}
						if method.args.len > 1 && can_have_data_args {
							data := if user_context.Context.req.method == .get {
								user_context.Context.query
							} else {
								user_context.Context.form
							}
							mut args := []string{cap: method.args.len + 1}
							for param in method.args[1..] {
								args << data[param.name]
							}
							// println('FOUND 1')
							app.$method(mut user_context, args)
						} else {
							// println('FOUND 2 $method.name')
							app.$method(mut user_context)
							// println('END OF METHOD CALLED')
						}
						return
					}
					if url_words.len == 0 && route_words == ['index'] && method.name == 'index' {
						if !validate_middleware[X](mut user_context, route.middlewares) {
							middleware_has_sent_response = true
							return
						}
						// println('FOUND 3')
						app.$method(mut user_context)
						return
					}
					if params := route_matches(url_words, route_words) {
						if !validate_middleware[X](mut user_context, route.middlewares) {
							middleware_has_sent_response = true
							return
						}
						// println('FOUND 4')
						app.$method(mut user_context, params)
						return
					}
				}
			}
		}
	}
	// println('not found')

	user_context.not_found()
	not_found = true
}

// --- Helper functions (kept from original) ---

fn generate_routes[A, X](app &A) !map[string]Route {
	mut routes := map[string]Route{}
	$for method in A.methods {
		$if method.return_type is Result {
			http_methods, route_path, host := parse_attrs(method.name, method.attrs) or {
				return error('error parsing method attributes: ${err}')
			}
			mut route := Route{
				methods: http_methods
				path:    route_path
				host:    host
			}
			$if A is MiddlewareApp {
				route.middlewares = app.Middleware.get_handlers_for_route[X](route_path)
				route.after_middlewares = app.Middleware.get_handlers_for_route_after[X](route_path)
			}
			routes[method.name] = route
		}
	}
	return routes
}

fn route_matches(url_words []string, route_words []string) ?[]string {
	if route_words.len == 1 && route_words[0].starts_with(':') && route_words[0].ends_with('...') {
		return ['/' + url_words.join('/')]
	}
	if url_words.len < route_words.len {
		return none
	}
	mut params := []string{cap: url_words.len}
	if url_words.len == route_words.len {
		for i in 0 .. url_words.len {
			if route_words[i].starts_with(':') {
				params << url_words[i]
			} else if route_words[i] != url_words[i] {
				return none
			}
		}
		return params
	}
	if route_words.len == 0 || !route_words[route_words.len - 1].ends_with('...') {
		return none
	}
	for i in 0 .. route_words.len - 1 {
		if route_words[i].starts_with(':') {
			params << url_words[i]
		} else if route_words[i] != url_words[i] {
			return none
		}
	}
	params << url_words[route_words.len - 1..url_words.len].join('/')
	return params
}

fn serve_if_static[A, X](app &A, mut user_context X, url urllib.URL, host string) bool {
	mut asked_path := url.path
	base_path := os.base(asked_path)
	if !base_path.contains('.') && !asked_path.ends_with('/') {
		asked_path += '/'
	}
	if asked_path.ends_with('/') {
		if app.static_files[asked_path + 'index.html'] != '' {
			asked_path += 'index.html'
		} else if app.static_files[asked_path + 'index.htm'] != '' {
			asked_path += 'index.htm'
		}
	}
	static_file := app.static_files[asked_path] or { return false }
	ext := os.file_ext(static_file).to_lower()
	mut mime_type := app.static_mime_types[ext] or { mime_types[ext] }
	static_host := app.static_hosts[asked_path] or { '' }
	if static_file == '' || mime_type == '' || (static_host != '' && static_host != host) {
		return false
	}
	user_context.file(static_file)
	return true
}

// Set s to the form error
pub fn (mut ctx Context) error(s string) {
	eprintln('[veb] Context.error: ${s}')
	ctx.form_error = s
}
