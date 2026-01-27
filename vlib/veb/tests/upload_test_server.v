module main

import veb
import os

struct Context {
	veb.Context
}

struct App {}

pub fn (mut app App) index(mut ctx Context) veb.Result {
	return ctx.html('
<!DOCTYPE html>
<html>
<head>
	<title>File Upload Test</title>
</head>
<body>
	<h1>Upload a Photo</h1>
	<form action="/upload" method="POST" enctype="multipart/form-data">
		<input type="file" name="photo" accept="image/*" required>
		<br><br>
		<input type="submit" value="Upload">
	</form>
</body>
</html>
')
}

@['/upload'; post]
pub fn (mut app App) upload(mut ctx Context) veb.Result {
	// Get uploaded files
	if 'photo' !in ctx.files {
		return ctx.request_error('No file uploaded')
	}

	photos := ctx.files['photo']
	if photos.len == 0 {
		return ctx.request_error('No file in photo field')
	}

	photo := photos[0]
	println('Received file: ${photo.filename}')
	println('Content-Type: ${photo.content_type}')
	println('Size: ${photo.data.len} bytes')

	// Save the file
	upload_dir := '/tmp/veb_uploads'
	os.mkdir_all(upload_dir) or {}
	filepath := os.join_path(upload_dir, photo.filename)
	os.write_file(filepath, photo.data) or {
		return ctx.server_error('Failed to save file: ${err}')
	}

	return ctx.html('
<!DOCTYPE html>
<html>
<head>
	<title>Upload Success</title>
</head>
<body>
	<h1>Upload Successful!</h1>
	<p>Filename: ${photo.filename}</p>
	<p>Content-Type: ${photo.content_type}</p>
	<p>Size: ${photo.data.len} bytes</p>
	<p>Saved to: ${filepath}</p>
	<br>
	<a href="/">Upload another</a>
</body>
</html>
')
}

fn main() {
	port := 8080
	println('Starting upload test server on http://localhost:${port}/')
	mut app := &App{}
	veb.run_at[App, Context](mut app, port: port, host: 'localhost')!
}
