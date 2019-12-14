The benefits of using V for web:
- 1
- 2

Let's start with installing V:

```
wget https://github.com/vlang/v/releases/latest/download/v_linux.zip
unzip v_linux.zip
cd v
sudo ./v symlink
```

Now V should be globally available on your system.

> On macOS use `v_macos.zip`, on Windows - `v_windows.zip`.
If you use a BSD system, Solaris, Android, or simply want to install V
from source, follow the simple instructions here:
https://github.com/vlang/v#installing-v-from-source


V projects can be created anywhere and don't need to have any structure:

```bash
mkdir blog
cd blog
touch blog.v
```

First let's create a simple hello world website:

```v
// blog.v
module main

import (
	vweb
)

struct App {
	vweb vweb.Context
}

fn main() {
	app := App{}
	vweb.run(mut app, 8080)
}

fn (app mut App) index() {
	app.vweb.text('Hello, world from vweb!')
}

pub fn (app &App) init() {}

```

Run it with

```bash
v run blog.v
```

and open http://localhost:8080/ in your browser:

<img width=662 src="https://github.com/medvednikov/v2/blob/tutorial/tutorials/hello.png?raw=true)">

The `App` struct is an entry point of our web application. If you have experience
with an MVC web framework, you can think of it as a controller. (Vweb is
not an MVC framework however.)

As you can see, there are no routing rules. The `index()` action handles the `/` request by default.
Vweb often uses convention over configuration, and adding a new action requires
no routing rules either:

```v
fn (app mut App) time() {
	app.vweb.text(time.now().format())
}
```


<img width=662 src="https://github.com/medvednikov/v2/blob/tutorial/tutorials/time.png?raw=true)">

>You have to rebuild and restart the website every time you change the code.
In the future Vweb will detect changes and recompile the website in the background
while it's running.

The `.text(string)` method obviously returns a plain text document with the provided
text, which isn't frequently used in websites.

Let's return an HTML view instead. Create `index.html` in the same directory:

```html
<html>
<header>
	<title>V Blog</title>
</header>
<body>
	<b>@message</b>
	<br>
	<img src='https://vlang.io/img/v-logo.png' width=100>
</body>
</html>
```

and update our `index()` action so that it returns the HTML view we just created:

```v
fn (app mut App) index() {
	message := 'Hello, world from Vweb!'
	$vweb.html()
}
```

<img width=662 src="https://github.com/medvednikov/v2/blob/tutorial/tutorials/hello_html.png?raw=true)">

Good, now we have an actual HTML page.

The V template language is similar to C#'s Razor: `@message` prints the value
of `message`.

You may notice something unsual: the `message` variable created in the `index()`
action is automatically available in the view.

It's another feature of Vweb to reduce the boilerplate in your web apps.
No need to create view models just to pass data, or use an unsafe and untyped
alternative, like C#'s `ViewBag["message"]`.

Making all action's variables available in the view may seem crazy,
but V is a language with pure functions by default, and you won't be able
to modify any data from a view. `<b>@foo.bar()</b>` will only work if the `bar()` method
doesn't modify `foo`.

The HTML template is compiled to V during the compilation of the website, that's done by the `$vweb.html()` line.
(`$` always means compile time actions in V.) offering the following benefits:

- Great performance, since the templates don't need to be compiled
on every request, like in almost every major web framework.

- Easier deployment, since all your HTML templates are  compiled
into a single binary file together with the web application itself.

- All errors in the templates are guaranteed to be caught during compilation.

### Fetching data with V ORM

Now let's display some articles!

We'll be using V's builtin ORM and a Postgres database.

Create a SQL file with the schema:
```sql
-- blog.sql
create table articles (
	id int serial primary key,
	title text default '',
	text text default ''
)
```



Add a Postgres DB handle to `App`:

```v
struct App {
mut:
	vweb vweb.Context
	db   pg.DB
}
```



Modify the `init()` method we created earlier to connect to a database:

```v
pub fn (app mut App) init() {
	db := pg.connect(pg.Config{
		host:   '127.0.0.1'
		dbname: 'blog'
		user:   'blog'
	}) or { panic(err) }
	app.db = db
}
```

Code in the `init()` function is run only once during app's startup, so we are going
to have one DB connection for all requests.

Create a new file `article.v`:


```v

module main

struct Article {
	id    int
	title string
	text  string
}

pub fn (app & App) find_all_articles() []Article {
	db := app.db
	articles := db.select from Article
	return articles
}
```












