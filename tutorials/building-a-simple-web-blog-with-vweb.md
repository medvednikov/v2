The benefits of using V for web:
- 1
- 2

Let's start with installing V:

```
wget https://github.com/vlang/v/releases/latest/download/v_macos.zip
unzip v_macos.zip
cd v
./v symlink
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

fn (app mut App) index() {
	app.vweb.text('Hello, world from vweb!')
}

pub fn (app &App) init() {}

fn main() {
	app := App{}
	vweb.run(mut app, 8080)
}
```

Run it with

```bash
v run blog.v
```

<img width=600 src="https://github.com/medvednikov/v2/blob/tutorial/tutorials/hello.png?raw=true)">

The `App` struct is an entry point of our web application. If you have experience
with an MVC web framework, you can think of it as a Controller. However vweb is
not an MVC framework.

The `index()` action handles the `/` request.

Vweb often uses convention over configuration, so adding a new action requires
no routing rules:

```v
fn (app mut App) time() {
	app.vweb.text(time.now().format())
}
```


<img width=600 src="https://github.com/medvednikov/v2/blob/tutorial/tutorials/time.png?raw=true)">

>You have to restart the running website every time you change the code.
In the future vweb will detect changes and recompile the website in the background
while it's running.

The `.text(str)` method obviously returns a plain text document with the provided
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
	message := 'Hello, world from vweb!'
	$vweb.html()
}
```

<img width=600 src="https://github.com/medvednikov/v2/blob/tutorial/tutorials/hello_html.png?raw=true)">







