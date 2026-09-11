--- === BindForge ===
---
--- Hotkeys as data, with an editor for them.
---
--- Bindings live in `hotkeys.json` in your Hammerspoon config — addressable by
--- id, rewritable at runtime, and applied to the live keyboard without an
--- `hs.reload()` that would destroy every open window's state. The editor draws
--- them as a keyboard you can click.
---
--- Two surfaces, one renderer:
---   * a Hammerspoon window  — nothing to start, no port
---   * a loopback HTTP page  — a real browser tab, for a bigger canvas
---
--- The binder and the editor ship together on purpose: `hotkeys.json`'s schema
--- is defined by one and written by the other, so splitting them across repos
--- would put a file-format contract across a version boundary.
---
--- Usage:
---   hs.loadSpoon("BindForge")
---   local binder = spoon.BindForge.binder      -- load()/applyAll()/setBinding()
---
--- Download: https://github.com/MadnessEngineering/BindForge.spoon

local obj = {}
obj.__index = obj

obj.name = "BindForge"
obj.version = "1.0"
obj.author = "Dan Edens"
obj.homepage = "https://github.com/MadnessEngineering/BindForge.spoon"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- BindForge.binder
--- Variable
--- The HotkeyBinder: reads and writes `hotkeys.json`, applies bindings live.
--- Your config drives this directly — `binder.load()`, `binder.applyAll()`.
obj.binder = nil

--- BindForge.window / BindForge.server
--- Variable
--- The two editor surfaces, once something has opened them — nil until then.
--- Exposed so a console or a health check can see their state
--- (`spoon.BindForge.window.win`, `spoon.BindForge.server.isRunning()`)
--- rather than having to guess at it.
---
--- Loaded on demand: building a webview or opening a port at spoon-load time
--- would be rude, so nothing here touches the screen until a hotkey asks.
obj.window = nil
obj.server = nil

--- Load a surface script and point it at this spoon's assets.
---
--- spoonPath is injected by hs.loadSpoon before init() runs, and unlike
--- hs.spoons.resourcePath it does not depend on which file happens to be
--- calling -- which matters, because these surfaces read assets from inside
--- webview and httpserver callbacks.
local function scripts(name)
    local mod = dofile(hs.spoons.resourcePath("scripts/" .. name))
    if mod and obj.spoonPath then mod.assetDir = obj.spoonPath .. "assets/" end
    return mod
end

--- BindForge:init()
--- Method
--- Loads the binder. Does NOT apply any bindings — your config decides when,
--- because it may want to define globals the bindings point at first.
function obj:init()
    -- HotkeyBinder stashes itself on _G._HotkeyBinder, so a second dofile
    -- returns the same table rather than starting a rival set of hs.hotkey
    -- handles that would shadow the first.
    self.binder = rawget(_G, "_HotkeyBinder") or dofile(hs.spoons.resourcePath("HotkeyBinder.lua"))
    return self
end

--- BindForge:start()
--- Method
--- Reads `hotkeys.json` and binds everything in it. Returns the number bound.
function obj:start()
    if not self.binder then self:init() end
    self.binder.load()
    return self.binder.applyAll()
end

--- BindForge:toggleWindow()
--- Method
--- Opens the editor in a Hammerspoon window, or closes it if it is already up.
function obj:toggleWindow()
    self.window = self.window or scripts("window.lua")
    return self.window.toggle()
end

--- BindForge:toggleServer()
--- Method
--- Serves the editor to a browser tab on localhost, or stops the server.
--- Token-gated, no CORS headers, localhost interface only.
function obj:toggleServer()
    self.server = self.server or scripts("server.lua")
    return self.server.toggle()
end

--- BindForge:serverURL()
--- Method
--- The running server's URL, or nil when it is stopped.
function obj:serverURL()
    if not self.server then return nil end
    return self.server.isRunning() and self.server.url() or nil
end

--- BindForge:reloadBindings()
--- Method
--- Re-reads `hotkeys.json` from disk and re-applies it. Cheaper than
--- `hs.reload()` and it keeps your windows.
function obj:reloadBindings()
    if not self.binder then self:init() end
    return self.binder.reload()
end

--- BindForge:bindHotkeys(mapping)
--- Method
--- Standard Spoon hotkey binding. Recognised keys: `window`, `server`,
--- `reload`. Most configs drive this from `hotkeys.json` instead and never
--- call it.
function obj:bindHotkeys(mapping)
    hs.spoons.bindHotkeysToSpec({
        window = hs.fnutils.partial(self.toggleWindow, self),
        server = hs.fnutils.partial(self.toggleServer, self),
        reload = hs.fnutils.partial(self.reloadBindings, self),
    }, mapping)
    return self
end

return obj
