module main

import (
	vweb
)

struct App {
mut:
	vweb vweb.Context
}

fn (app mut App) index() {
	app.vweb.text('Hello, world from vweb!')
}
pub fn (app & App) init() {} 

fn main() {
	app := App{}
	vweb.run(mut app, 8080)
}
