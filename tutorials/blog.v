module main

import (
	vweb
	time
)

struct App {
mut:
	vweb vweb.Context
}

fn (app mut App) index2() {
	app.vweb.text('Hello, world from vweb!')
}

fn (app &App) index() {
	message := 'Hello, world from vweb!'
	$vweb.html()
}

pub fn (app & App) init() {}

fn (app mut App) time() {
	app.vweb.text('2019-12-14 09:54') //time.now().format())
}

fn main() {
	app := App{}
	vweb.run(mut app, 8080)
}
