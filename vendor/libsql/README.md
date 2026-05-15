# libSQL SQLite C API

SQLite-compatible C API for the storage layer.

Source: https://github.com/tursodatabase/libsql

## Building

Build libSQL from a gitignored checkout under this repo:

```bash
git clone https://github.com/tursodatabase/libsql third_party/libsql
cd third_party/libsql/libsql-sqlite3
./configure
make
```

The Nova runtime looks for the library in this order:

- macOS: `third_party/libsql/libsql-sqlite3/.libs/libsqlite3.0.dylib`, `third_party/libsql/libsql-sqlite3/.libs/liblibsql.0.dylib`, then loader-path fallbacks.
- Linux: `third_party/libsql/libsql-sqlite3/.libs/libsqlite3.so`, `third_party/libsql/libsql-sqlite3/.libs/liblibsql.so`, then loader-path fallbacks.
- Windows: `third_party\\libsql\\libsql-sqlite3\\.libs\\sqlite3.dll`, then `sqlite3.dll` on the loader path.

## Updating the header

After rebuilding or updating libSQL, refresh the vendored header:

```bash
cp third_party/libsql/libsql-sqlite3/sqlite3.h vendor/libsql/sqlite3.h
```
