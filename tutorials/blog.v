module main

import (
	vweb
	time
	pg
)

struct App {
mut:
	vweb vweb.Context
	db pg.DB
}

fn (app mut App) index2() {
	app.vweb.text('Hello, world from vweb!')
}

fn (app &App) index() {
	message := 'Hello, world from vweb!'
	$vweb.html()
}

pub fn (app mut App) init() {
	db := pg.connect(pg.Config{
		host:   '127.0.0.1'
		dbname: 'blog'
		user:   'alex'
	}) or { panic(err) }
	app.db = db
}

fn (app mut App) time() {
	app.vweb.text('2019-12-14 09:54') //time.now().format())
}

fn main() {
	app := App{}
	vweb.run(mut app, 8080)
}
