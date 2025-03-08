// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module http

import net.ssl
import strings
import time

fn (req &Request) ssl_do(port int, method Method, host_name string, path string) !Response {
	$if windows && !no_vschannel ? {
		return vschannel_ssl_do(req, port, method, host_name, path)
	}
	return net_ssl_do(req, port, method, host_name, path)
}

fn net_ssl_do(req &Request, port int, method Method, host_name string, path string) !Response {
	println('ssl do(${path})')
	mut ssl_conn := ssl.new_ssl_conn(
		verify:                 req.verify
		cert:                   req.cert
		cert_key:               req.cert_key
		validate:               req.validate
		in_memory_verification: req.in_memory_verification
	)!
	mut retries := 0
	for {
		ssl_conn.dial(host_name, port) or {
			retries++
			if is_no_need_retry_error(err.code()) || retries >= req.max_retries {
				return err
			}
			continue
		}
		break
	}

	req_headers := req.build_request_headers(method, host_name, port, path)
	$if trace_http_request ? {
		eprint('> ')
		eprint(req_headers)
		eprintln('')
	}

	return req.do_request(req_headers, mut ssl_conn)!
}

fn read_from_ssl_connection_cb(con voidptr, buf &u8, bufsize int) !int {
	mut ssl_conn := unsafe { &ssl.SSLConn(con) }
	return ssl_conn.socket_read_into_ptr(buf, bufsize)
}

fn (req &Request) do_request(req_headers string, mut ssl_conn ssl.SSLConn) !Response {
	ssl_conn.write_string(req_headers) or { return err }
	mut content := strings.new_builder(4096)
	req.receive_all_data_from_cb_in_builder(mut content, voidptr(ssl_conn), read_from_ssl_connection_cb)!
	// ssl_conn.shutdown()!
	response_text := content.str()
	$if trace_http_response ? {
		eprint('< ')
		eprint(response_text)
		eprintln('')
	}
	if req.on_finish != unsafe { nil } {
		req.on_finish(req, u64(response_text.len))!
	}
	resp := parse_response(response_text)!
	println('\n\nSSL RESP=${resp}')
	if resp.header.get(.transfer_encoding) or { '' } == 'chunked' {
		println('SSL IS CHUNKED sleeping')
		time.sleep(7 * time.second)
		req.receive_all_data_from_cb_in_builder(mut content, voidptr(ssl_conn), read_from_ssl_connection_cb)!
		println('DA STR=')
		println(content.str())
	}
	ssl_conn.shutdown()!
	return resp
}

/*
fn (req &Request) do_request(req_headers string, mut ssl_conn ssl.SSLConn) !Response {
	ssl_conn.write_string(req_headers) or { return err }

	// Read initial response (headers)
	mut content := strings.new_builder(4096)
	req.receive_all_data_from_cb_in_builder(mut content, voidptr(ssl_conn), read_from_ssl_connection_cb)!
	initial_response := content.str()

	// Parse headers to check for chunked encoding
	mut resp := parse_response(initial_response) or {
		// If parsing fails (e.g., incomplete), assume chunked and proceed
		mut full_content := strings.new_builder(4096)
		full_content.write_string(initial_response) // Keep what we have
		for {
			mut buf := []u8{len: 4096}
			n := ssl_conn.socket_read_into(mut buf) or { break }
			if n == 0 {
				break
			}
			full_content.write(buf[..n])
			$if trace_http_response_chunk ? {
				println('Read chunk of ${n} bytes: ${buf[..n].bytestr()}')
			}
		}
		response_text := full_content.str()
		ssl_conn.shutdown()!
		$if trace_http_response ? {
			eprint('< ')
			eprint(response_text)
			eprintln('')
		}
		if req.on_finish != unsafe { nil } {
			req.on_finish(req, u64(response_text.len))!
		}
		return parse_response(response_text)!
	}

	// Check if response is chunked
	if resp.header.get(.transfer_encoding) or { '' } == 'chunked' {
		// Keep reading chunks until EOF
		mut full_content := strings.new_builder(4096)
		full_content.write_string(initial_response) // Include headers and any initial body
		for {
			mut buf := []u8{len: 4096}
			n := ssl_conn.socket_read_into(mut buf) or { break }
			if n == 0 {
				break
			}
			full_content.write(buf[..n])
			$if trace_http_response_chunk ? {
				println('Read chunk of ${n} bytes: ${buf[..n].bytestr()}')
			}
		}
		response_text := full_content.str()
		ssl_conn.shutdown()!
		$if trace_http_response ? {
			eprint('< ')
			eprint(response_text)
			eprintln('')
		}
		if req.on_finish != unsafe { nil } {
			req.on_finish(req, u64(response_text.len))!
		}
		return parse_response(response_text)!
	}

	// Non-chunked case: shutdown and return
	ssl_conn.shutdown()!
	$if trace_http_response ? {
		eprint('< ')
		eprint(initial_response)
		eprintln('')
	}
	if req.on_finish != unsafe { nil } {
		req.on_finish(req, u64(initial_response.len))!
	}
	return resp
}
*/
