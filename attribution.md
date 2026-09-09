# Third-party attributions

Nova vendors a small number of third-party libraries and compiles a few
build-time dependencies into the binary. Each entry lists the source,
license, and any local modifications.

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

## Lua 5.4 (Lua plugin system)

- **Source:** <https://www.lua.org> (Lua.org, PUC-Rio, Brazil)
- **Version:** 5.4.7 (vendored at `vendor/lua/`)
- **License:** MIT — Copyright (C) 1994-2024 Lua.org, PUC-Rio
- **Used for:** the embedded Lua VM that runs user plugins (tool
  registration, event hooks, sandboxed API). Compiled directly into the
  binary via `build.zig`; the full standard library (`lbaselib.c`,
  `linit.c`, …) is vendored.

No local modifications — vendored unmodified from the 5.4.7 release.

The MIT license text follows:

```
Copyright (C) 1994-2024 Lua.org, PUC-Rio, Brazil

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
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH
THE SOFTWARE.
```

## SQLite (session database)

- **Source:** <https://www.sqlite.org> (SQLite amalgamation)
- **Version:** 3.53.4 (vendored at `vendor/sqlite/`)
- **License:** Public domain — no license required. From the amalgamation
  header (`vendor/sqlite/sqlite3.h`):

  > 2001-09-15
  >
  > The author disclaims copyright to this source code. In place of a legal
  > notice, here is a blessing:
  >
  >    May you do good and not evil.
  >    May you find forgiveness for yourself and forgive others.
  >    May you share freely, never taking more than you give.

- **Used for:** session persistence (conversation history, transcripts) via
  the `src/session.zig` store.

No local modifications — vendored unmodified from the 3.53.4 amalgamation
(replaces the earlier libsql dependency).

## websocket.zig (MCP stdio/WebSocket transport)

- **Source:** <https://github.com/karlseguin/websocket.zig>
- **Version:** current master (files byte-identical to upstream at the time
  of the last dep bump `eab9fed`; vendored at `vendor/websocket.zig/`)
- **License:** MIT — Copyright (c) 2024 Karl Seguin
- **Used for:** the WebSocket client used by the MCP transport
  (`lib/websocket.zig` re-exports the vendored client).

### Local modifications

- **`src/websocket.zig`** — the server-side exports (`server` namespace,
  `Conn`/`Config`/`Server`/`blockingMode`/`Handshake` re-exports) and the
  `frame*` test helpers were removed from the public entry point. Nova only
  uses the client; all other vendored files (`buffer.zig`, `posix.zig`,
  `proto.zig`, `windows.zig`, `client/client.zig`) are byte-identical to
  upstream.

The MIT license text follows (kept verbatim at `vendor/websocket.zig/LICENSE`).

## zigdown → `lib/terminal_markdown.zig` (transcript markdown rendering)

- **Source:** <https://github.com/JacobCrabill/zigdown>
- **Version:** as vendored 2026-05 (`f65f476`)
- **License:** MIT — Copyright 2024 Jacob Crabill <github.com/JacobCrabill>
- **Used for:** rendering markdown in the transcript (`lib/terminal_markdown.zig`,
  imported by `src/transcript.zig` and the message/status widgets). The
  renderer was vendored from zigdown into `lib/terminal_markdown.zig`; the
  source files were later pruned from `vendor/zigdown/`, leaving only
  `LICENSE.txt`, which is kept for attribution.

The MIT license text follows (kept verbatim at `vendor/zigdown/LICENSE.txt`).

## Build-time dependencies (compiled into the binary)

These are Zig packages pinned in `build.zig.zon` and fetched at build time
into `zig-pkg/` (gitignored). They are not vendored source, but they are
compiled into the shipped binary, so their licenses are listed here.

### vaxis (TUI framework)

- **Source:** <https://github.com/rockorager/libvaxis>
- **Version:** 0.6.0 @ `c060d31`
- **License:** MIT — Copyright (c) 2023 Tim Culverhouse
- **Used for:** the terminal user interface (widget tree, event loop,
  drawing).

#### Local modifications

Two guards (marked `NOVA-LOCAL-PATCH`) in `zig-pkg/vaxis-<hash>/src/vxfw/App.zig`
fix an upstream focus-handler crash (SIGSEGV in ReleaseFast) when
`path_to_focused` is empty during session switch:

1. `FocusHandler.update` — falls back to `self.root` when the focus path is
   empty.
2. `FocusHandler.handleEvent` — returns early instead of asserting
   `path.len > 0`.

The vendor directory is gitignored, so the patch must be re-applied after
every `zig build --fetch` / vaxis bump. Remove both once the upstream fix
lands past the pinned commit.

### zigimg (image rendering)

- **Source:** <https://github.com/zigimg/zigimg>
- **Version:** 0.1.0 @ `a7440df`
- **License:** MIT — Copyright (c) 2019-2021 zigimg developers
- **Used for:** terminal image rendering (transcript images). No local
  modifications.

### uucode (Unicode tables)

- **Source:** <https://github.com/jacobsandlund/uucode>
- **Version:** 0.2.0 @ `2826a37` (transitive dependency of vaxis, pulled in
  via vaxis's own dependency pin — the root build.zig.zon's lazy `0620982`
  entry is never fetched)
- **License:** MIT — Copyright (c) 2026 Jacob Sandlund
- **Used for:** Unicode-aware string handling inside vaxis (grapheme/width
  tables). No local modifications.

### models.dev snapshot (model catalog data)

- **Source:** <https://models.dev> (<https://github.com/anomalyco/models.dev>)
- **Version:** snapshot vendored at `vendor/models.dev/` (`api.json`,
  `models.json`)
- **License:** MIT — Copyright (c) 2025 models.dev
- **Used for:** the offline model/provider catalog. Installed next to the
  binary as `share/nova/api.json` (`build.zig`) and refreshed on demand via
  the `/v1/models` probe.

## Safety classifier service (`tools/classifier/`)

- **What it is:** the standalone command-safety classifier (FastAPI service,
  `POST /classify`). Its Python dependencies (fastapi, uvicorn, onnxruntime,
  transformers) come from PyPI via `uv` — see `tools/classifier/uv.lock`.
- **Model weights:** the default `ModernBERT-bash-classifier` weights (in
  `vendor/local-models/`, gitignored) are a local fine-tune of
  [answerdotai/ModernBERT-base](https://huggingface.co/answerdotai/ModernBERT-base),
  which is **Apache-2.0**. The fine-tune weights inherit that license.

  ```
  Apache License
  Version 2.0, January 2004 — http://www.apache.org/licenses/

  Copyright 2023 Answer.AI

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  ```
