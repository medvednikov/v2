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

If you are on macOS, use `v_macos.zip`, if you are on Windows, use `v_windows.zip`.

If you use a BSD system, Solaris, Android, follow the simple instructions
to install V from source: https://github.com/vlang/v#installing-v-from-source

Now V should be globally available on your system.

V projects can be created anywhere and don't need to have any structure:

```bash
mkdir blog
cd blog
touch blog.v
```

Let's create a simple hello world website:

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

fn main() {
	app := App{}
	vweb.run(mut app, 8080)
}
```


