module main

import (
	vweb
	time
)

struct App {
mut:
	vweb vweb.Context
}

fn (app mut App) index() {
	app.vweb.text('Hello, world from vweb!')
}
pub fn (app & App) init() {}

fn (app mut App) time() {
	app.vweb.text('2019-12-14 09:54') //time.now().format())
}

fn main() {
	app := App{}
	vweb.run(mut app, 8080)
}
