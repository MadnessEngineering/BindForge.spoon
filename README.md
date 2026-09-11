# BindForge.spoon

Hotkeys as data, with an editor for them.

Your bindings live in `hotkeys.json` in your Hammerspoon config — addressable by
id, rewritable at runtime, and applied to the live keyboard without an
`hs.reload()` that would destroy every open window's state. The editor draws them
as a keyboard you can click.

Two surfaces, one renderer:

| | |
| --- | --- |
| **Window** | a Hammerspoon webview. Nothing to start, no port. |
| **Browser** | a loopback HTTP page, for a bigger canvas or a second monitor. |

The board sizes itself to whatever window it is given, with a `− / Fit / +`
control and ⌘−, ⌘+, ⌘0. If a palette file is present you also get a theme picker.

## Install

```sh
git clone https://github.com/MadnessEngineering/BindForge.spoon.git \
  ~/.hammerspoon/Spoons/BindForge.spoon
```

```lua
hs.loadSpoon("BindForge")
spoon.BindForge:start()            -- read hotkeys.json and bind it

spoon.BindForge:bindHotkeys({
    window = { { "cmd", "ctrl", "alt", "shift" }, ";" },
    server = { { "cmd", "ctrl", "alt" }, ";" },
    reload = { { "cmd", "ctrl", "alt" }, "'" },
})
```

Most configs skip `bindHotkeys` and point at the methods from `hotkeys.json`
itself, so the editor's own keys are editable in the editor.

## hotkeys.json

```json
{
  "modifierSets": { "hammer": ["cmd", "ctrl", "alt"] },
  "bindings": [
    {
      "id": "hammer+b",
      "mods": "hammer",
      "key": "b",
      "description": "Chrome",
      "action": { "kind": "call", "fn": "AppManager.open_chrome" }
    }
  ]
}
```

`mods` is a named set or an explicit list. `action.kind` is `call` (a dotted
path to a function, plus optional `args`), `none` (reserve the key), or `action`.

`action` hands off to a host-provided action system, and the editor offers that
kind only when one is registered:

```lua
spoon.BindForge.actionSystem = myActionSystem   -- executeAction(spec)
                                                -- getActionTypesForUI()
```

That is what lets one editor serve a config with an action system and one
without, rather than each carrying its own edit.

Function paths resolve **at press time**, so a binding may point at something
that does not exist yet — a Spoon loaded later, say — and a module reloaded in
the console is picked up without rebinding.

## API

| | |
| --- | --- |
| `spoon.BindForge.binder` | the HotkeyBinder: `load()`, `applyAll()`, `setBinding()`, `deleteBinding()`, `verify()` |
| `:start()` | read `hotkeys.json` and bind it; returns the count |
| `:toggleWindow()` | editor in a Hammerspoon window |
| `:toggleServer()` | editor in a browser tab |
| `:serverURL()` | the running URL, or nil |
| `:reloadBindings()` | re-read from disk and re-apply, keeping your windows |

`hs.inspect(spoon.BindForge.binder.verify())` lists bindings whose function path
no longer resolves.

## The browser surface

It opens a port, so: localhost interface only, Bonjour off, a per-start random
token required on every `/api/` call that lives only inside the served page, and
no CORS headers — so a site you happen to be visiting cannot rebind your keys.
Off unless you turn it on, and stops when Hammerspoon quits.

## Themes

Drop a `keymap_themes.js` into `assets/` defining `window.KeymapThemes` — an
array of `{ name, displayName, icon, tokens }`, where `tokens` maps CSS custom
properties. Absent, the picker hides itself.

## Optional assets

`param_widgets.js` (typed action parameters) and `keymap_themes.js` are both
optional. A missing one means fewer knobs, not a broken page.
