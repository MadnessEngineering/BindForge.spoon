# BindForge.spoon

> *Hotkeys come off the anvil as data, not as source you have to recompile in your head.*

A Hammerspoon Spoon that keeps every keybinding in one JSON file and gives you a
keyboard on screen to edit it. Change a key, and it is bound before your hand
leaves the mouse — no `hs.reload()`, so nothing you had open goes away.

```
  hotkeys.json ──▶ HotkeyBinder ──▶ live hs.hotkey handles
       ▲                 ▲
       │                 │  same table, both directions
       └──── editor ─────┘
             ├── a Hammerspoon window   (no port, nothing to start)
             └── a localhost HTTP page  (a real browser tab)
```

Both surfaces are the same renderer over a different transport. Swap the
transport and the editor runs somewhere else; that is the whole trick.

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

`hotkeys.json` lives in **your** config (`hs.configdir`), never in this spoon.
Your bindings are yours; this is only the machinery that works them.

## The stock

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

| Field | |
| --- | --- |
| `mods` | a named set from `modifierSets`, or an explicit list like `["cmd","shift"]` |
| `action.kind` | `call`, `none`, or `action` |
| `call` | a dotted path to a function, plus optional `args` |
| `none` | reserve the key and do nothing — useful for staking a claim |
| `action` | hand off to a host-registered action system (below) |
| `enabled` | `false` to keep an entry without binding it |
| `noRepeat` | suppress key-repeat, for toggles |

Function paths resolve **at press time**, not at bind time. A binding may point
at something that does not exist yet — a Spoon loaded later — and a module
reloaded in the console is picked up without rebinding anything.

## Giving a key a bigger vocabulary

`action` bindings hand off to whatever action system the host registers:

```lua
spoon.BindForge.actionSystem = myActionSystem   -- executeAction(spec)
                                                -- getActionTypesForUI()
```

The editor offers that kind only when one is registered. That is what lets a
single copy of this spoon serve a config with an action system and one without,
rather than each carrying its own private edit.

## API

| | |
| --- | --- |
| `spoon.BindForge.binder` | the HotkeyBinder: `load()`, `applyAll()`, `setBinding()`, `deleteBinding()`, `verify()` |
| `:start()` | read `hotkeys.json` and bind it; returns the count |
| `:toggleWindow()` | editor in a Hammerspoon window |
| `:toggleServer()` | editor in a browser tab |
| `:serverURL()` | the running URL, or nil |
| `:reloadBindings()` | re-read from disk and re-apply, keeping your windows |
| `.window` / `.server` | the loaded surfaces, for poking at from the console |

When a key goes quiet, this is the first thing to run:

```lua
hs.inspect(spoon.BindForge.binder.verify())
```

It lists bindings whose function path no longer resolves — usually a renamed
module, occasionally a typo that has been sitting there for a month.

## At the board

The keyboard sizes itself to whatever window it is given: **Fit** is the
default and re-runs on resize, `−` / `+` pin a size, and ⌘−, ⌘+, ⌘0 do the same
from the keyboard. A theme picker appears if palettes are installed.

Keys are coloured by what is on them, and a key that failed to bind says so —
macOS quietly owns more combinations than you would guess, and
`RegisterEventHotKey` failing is otherwise invisible.

## The browser surface opens a port

Worth being plain about, since it edits your keyboard:

- **localhost interface only**, and Bonjour advertising off.
- Every `/api/` call carries a **random token regenerated at each start**, which
  lives only inside the page the server itself serves — never in the URL.
- **No CORS headers, ever.** A page on another origin can reach the port, but a
  request with a custom header needs a preflight this server does not answer,
  and could not read the response anyway. That is what stops a site you happen
  to be visiting from rebinding your keys.

Loopback alone would not be enough — anything running as you can reach
127.0.0.1, and browsers will happily send cross-origin requests to it.

The server is off until you turn it on, and stops when Hammerspoon quits. The
window surface opens no port at all.

## Themes

Drop a `keymap_themes.js` into `assets/` defining `window.KeymapThemes` — an
array of `{ name, displayName, icon, tokens }`, where `tokens` maps CSS custom
properties. Absent, the picker hides itself.

## Optional assets

`param_widgets.js` (typed action parameters) and `keymap_themes.js` are both
optional. A missing one means fewer knobs, not a broken page.

---

Part of [Madness Interactive](https://github.com/MadnessEngineering). MIT.
