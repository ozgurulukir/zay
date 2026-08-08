# Third-party attributions

Nova vendors a small number of third-party libraries. Each entry lists the
source, license, and any local modifications.

## fzy (fuzzy file matching)

- **Source:** <https://github.com/jhawthorn/fzy>
- **Version:** 1.1 (vendored at `vendor/fzy/`)
- **License:** MIT — Copyright (c) 2014 John Hawthorn
- **Used for:** scoring filepath candidates in the `@` at-search autocomplete
  and the `find` search operation. Only the `match.c` / `match.h` / `bonus.h`
  matcher is vendored; the interactive TTY frontend is not.

### Local modifications

1. **`src/match.c`** — removed `#include <strings.h>`. The file declares it
   but never uses `strcasecmp`/`strncasecmp` (only the local `strcasechr`
   helper, which uses `strpbrk` from `<string.h>`). `strings.h` does not exist
   on Windows, so this keeps the vendored source cross-platform.
2. **`src/match.h`** — added `#include <stddef.h>` so `size_t` is declared
   when the header is included standalone (as Nova does via `src/c.h`).

The MIT license text follows:

```
The MIT License (MIT)

Copyright (c) 2014 John Hawthorn

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
