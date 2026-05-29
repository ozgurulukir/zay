Write a complete file in one call. Creates the file, or overwrites it entirely if it exists.

Use only for new files or full rewrites. To change part of an existing file, use `edit_file` instead.

`content` is the entire file body — never a patch or diff, and never the path. Parent directories are created automatically.
