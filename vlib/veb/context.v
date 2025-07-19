module veb

import json
import net
import net.http
import os

enum ContextReturnType {
	normal
	file
}

pub enum RedirectType {
	found              = int(http.Status.found)
	moved_permanently  = int(http.Status.moved_permanently)
	see_other          = int(http.Status.see_other)
	temporary_redirect = int(http.Status.temporary_redirect)
	permanent_redirect = int(http.Status.permanent_redirect)
}

// The Context struct represents the Context which holds the HTTP request and response.
// It has fields for the query, form, files and methods for handling the request and response
@[heap]
pub struct Context {
pub mut:
	// TODO pub
	// veb will try to infer the content type base on file extension,
	// and if `content_type` is not empty the `Content-Type` header will always be
	content_type string
	// done is set to true when a response has been prepared
	done bool
	// if true, a warning will be logged. Connection takeover is not supported by this backend.
	takeover bool
	// These fields are kept for API compatibility but have limited function.
	// return_type will be set, but the server does not stream files.
	return_type ContextReturnType = .normal
	return_file string
	// if true the `Connection: close` header will be added to the response
	client_wants_to_close bool
	req                   http.Request
	custom_mime_types     map[string]string
	// TCP connection to client. Only for advanced usage!
	conn &net.TcpConn = unsafe { nil }
	// Map containing query params for the route.
	// http://localhost:3000/index?q=vpm&order_by=desc => { 'q': 'vpm', 'order_by': 'desc' }
	query map[string]string
	// Multipart-form fields.
	form map[string]string
	// Files from multipart-form.
	files map[string][]http.FileData
	res   http.Response
	// use form_error to pass errors from the context to your frontend
	form_error                  string
	livereload_poll_interval_ms int = 250 // Kept for API compatibility
pub:
	// time.ticks() from start of veb connection handle.
	// You can use it to determine how much time is spent on your request.
	page_gen_start i64
}

// returns the request header data from the key
pub fn (ctx &Context) get_header(key http.CommonHeader) !string {
	return ctx.req.header.get(key)!
}

// returns the request header data from the key
pub fn (ctx &Context) get_custom_header(key string) !string {
	return ctx.req.header.get_custom(key)!
}

// set a header on the response object
pub fn (mut ctx Context) set_header(key http.CommonHeader, value string) {
	ctx.res.header.set(key, value)
}

// set a custom header on the response object
pub fn (mut ctx Context) set_custom_header(key string, value string) ! {
	ctx.res.header.set_custom(key, value)!
}

// send_response_to_client finalizes the response headers and *prepares* the response object.
// It NO LONGER sends data. The server loop sends the response after the handler returns.
pub fn (mut ctx Context) send_response_to_client(mimetype string, response string) Result {
	if ctx.done {
		eprintln('[veb] a response cannot be sent twice over one connection')
		return Result{}
	}
	ctx.done = true
	ctx.res.body = response

	// set Content-Type and Content-Length headers
	mut custom_mimetype := if ctx.content_type.len == 0 { mimetype } else { ctx.content_type }
	if custom_mimetype != '' {
		ctx.res.header.set(.content_type, custom_mimetype)
	}
	if ctx.res.body != '' {
		ctx.res.header.set(.content_length, ctx.res.body.len.str())
	}
	// send veb's closing headers
	ctx.res.header.set(.server, 'veb')
	if ctx.client_wants_to_close {
		ctx.res.header.set(.connection, 'close')
	}
	// set the http version
	ctx.res.set_version(.v1_1)
	if ctx.res.status_code == 0 {
		ctx.res.set_status(.ok)
	}

	return Result{}
}

// Response with payload and content-type `text/html`
pub fn (mut ctx Context) html(s string) Result {
	return ctx.send_response_to_client('text/html', s)
}

// Response with `s` as payload and content-type `text/plain`
pub fn (mut ctx Context) text(s string) Result {
	return ctx.send_response_to_client('text/plain', s)
}

// Response with json_s as payload and content-type `application/json`
pub fn (mut ctx Context) json[T](j T) Result {
	json_s := json.encode(j)
	return ctx.send_response_to_client('application/json', json_s)
}

// Response with a pretty-printed JSON result
pub fn (mut ctx Context) json_pretty[T](j T) Result {
	json_s := json.encode_pretty(j)
	return ctx.send_response_to_client('application/json', json_s)
}

// Response HTTP_OK with file as payload.
// NOTE: This now reads the ENTIRE file into memory. It does not stream.
pub fn (mut ctx Context) file(file_path string) Result {
	if !os.exists(file_path) {
		eprintln('[veb] file "${file_path}" does not exist')
		return ctx.not_found()
	}

	ext := os.file_ext(file_path)

	mut content_type := ctx.content_type
	if content_type.len == 0 {
		if ct := ctx.custom_mime_types[ext] {
			content_type = ct
		} else {
			content_type = mime_types[ext]
		}
	}

	if content_type.len == 0 {
		eprintln('[veb] no MIME type found for extension "${ext}"')
		return ctx.server_error('')
	}

	ctx.return_type = .file
	ctx.return_file = file_path

	// Read the entire file into memory and prepare it as a normal response.
	data := os.read_file(file_path) or {
		eprintln('[veb] error while trying to read file: ${err.msg()}')
		return ctx.server_error('could not read resource')
	}
	return ctx.send_response_to_client(content_type, data)
}

// Response HTTP_OK with s as payload
pub fn (mut ctx Context) ok(s string) Result {
	mut mime := if ctx.content_type.len == 0 { 'text/plain' } else { ctx.content_type }
	return ctx.send_response_to_client(mime, s)
}

// send an error 400 with a message
pub fn (mut ctx Context) request_error(msg string) Result {
	ctx.res.set_status(.bad_request)
	return ctx.send_response_to_client('text/plain', msg)
}

// send an error 500 with a message
pub fn (mut ctx Context) server_error(msg string) Result {
	ctx.res.set_status(.internal_server_error)
	return ctx.send_response_to_client('text/plain', msg)
}

// send an error with a custom status
pub fn (mut ctx Context) server_error_with_status(s http.Status) Result {
	ctx.res.set_status(s)
	return ctx.send_response_to_client('text/plain', 'Server error')
}

// send a 204 No Content response without body and content-type
pub fn (mut ctx Context) no_content() Result {
	ctx.res.set_status(.no_content)
	return ctx.send_response_to_client('', '')
}

@[params]
pub struct RedirectParams {
pub:
	typ RedirectType
}

// Redirect to an url
pub fn (mut ctx Context) redirect(url string, params RedirectParams) Result {
	status := http.Status(params.typ)
	ctx.res.set_status(status)

	ctx.res.header.add(.location, url)
	return ctx.send_response_to_client('text/plain', status.str())
}

// before_request is always the first function that is executed and acts as middleware
pub fn (mut ctx Context) before_request() Result {
	return Result{}
}

// returns a HTTP 404 response
pub fn (mut ctx Context) not_found() Result {
	ctx.res.set_status(.not_found)
	return ctx.send_response_to_client('text/plain', '404 Not Found')
}

// Gets a cookie by a key
pub fn (ctx &Context) get_cookie(key string) ?string {
	if cookie := ctx.req.cookie(key) {
		return cookie.value
	} else {
		return none
	}
}

// Sets a cookie
pub fn (mut ctx Context) set_cookie(cookie http.Cookie) {
	cookie_raw := cookie.str()
	if cookie_raw == '' {
		eprintln('[veb] error setting cookie: name of cookie is invalid.\n${cookie}')
		return
	}
	ctx.res.header.add(.set_cookie, cookie_raw)
}

// set_content_type sets the Content-Type header to `mime`
pub fn (mut ctx Context) set_content_type(mime string) {
	ctx.content_type = mime
}

// takeover_conn prevents veb from automatically sending a response and closing
// the connection. You are responsible for closing the connection.
// NOTE: True connection takeover for SSE/WebSockets is not supported by this server backend.
// This function will only set a flag and the server will log a warning.
pub fn (mut ctx Context) takeover_conn() {
	ctx.takeover = true
}

// user_agent returns the user-agent header for the current client
pub fn (ctx &Context) user_agent() string {
	return ctx.req.header.get(.user_agent) or { '' }
}

// Returns the ip address from the current user
pub fn (ctx &Context) ip() string {
	mut ip := ctx.req.header.get_custom('CF-Connecting-IP') or { '' }
	if ip == '' {
		ip = ctx.req.header.get(.x_forwarded_for) or { '' }
	}
	if ip == '' {
		ip = ctx.req.header.get_custom('X-Forwarded-For') or { '' }
	}
	if ip == '' {
		ip = ctx.req.header.get_custom('X-Real-Ip') or { '' }
	}
	if ip.contains(',') {
		ip = ip.all_before(',')
	}
	if ip == '' {
		ip = ctx.conn.peer_ip() or { '' }
	}
	return ip
}
