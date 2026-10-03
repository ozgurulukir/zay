# Plugin Store and Packages

This directory contains the checked-in store catalog and the plugin packages
distributed with Zay. Each `plugins/packages/<id>/` directory is the canonical
source for that package; the catalog points at these packages both locally and
on GitHub. Keeping packages one level below the catalog also keeps their
prompts out of the checkout's project-plugin prompt scan.

When Zay runs outside this checkout, it fetches this catalog from
`https://raw.githubusercontent.com/ozgurulukir/zay/main/plugins/store.json`.

Open `/plugins` in the TUI to browse the catalog, install a plugin, add another
catalog URL, or refresh the available entries. Installs are staged and then
published atomically into the user's global plugin directory
(`~/.config/zay/plugins/`, or `%APPDATA%\\zay\\plugins` on Windows), so using
the store from a checkout does not modify the checkout. A newly installed
plugin is loaded when the next runtime/session starts; the current Lua state is
never unloaded from a live turn.

Additional catalogs are JSON documents with this shape:

```json
{
  "name": "Example Store",
  "plugins": [
    {
      "id": "my-plugin",
      "name": "My Plugin",
      "version": "1.0.0",
      "description": "Short description.",
      "files": [
        { "path": "plugin.lua", "url": "https://example.com/my-plugin/plugin.lua" },
        { "path": "init.lua", "url": "https://example.com/my-plugin/init.lua" }
      ]
    }
  ]
}
```

`plugin.lua` and `init.lua` are required. Remote file paths are relative to the
plugin package and URLs must be HTTP(S). The checked-in catalog also has a
`sourceDir` for each package, used only when running from this checkout. Store
URLs are saved globally in `plugin-stores.json` under Zay's platform config
directory. The checked-in packages are store sources, not the install
destination.
