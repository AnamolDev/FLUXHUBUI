# Flux Hub UI

A single-file Roblox Luau UI library for executor-side scripts: a window with an icon tab strip,
live search, collapsible section cards, twelve controls, theming, config files, keybinds,
notifications and tooltips — bundled into one file you `loadstring` and never configure.

```lua
local Flux = loadstring(game:HttpGet("https://raw.githubusercontent.com/AnamolDev/FLUXHUBUI/main/dist/FluxHub.lua"))()
```

The published artifact is [`dist/FluxHub.lua`](dist/FluxHub.lua)
(~394 KB, 42 modules, no dependencies). Everything under [`src/`](src)
is the same library split into modules; the bundle is generated, so edit `src/` and rebuild.

[`example/Showcase.lua`](example/Showcase.lua) is a whole hub written against the public API. It
renders as: flat dark panels, hairline borders, one accent colour, a horizontal icon tab strip instead
of a left sidebar, full-width control rows with the label on the left and the widget on the right,
and a search field in the header.

---

## Quick start

```lua
local Flux = loadstring(game:HttpGet(url))()

local Window = Flux:Window({
    Title = "Flux",
    Subtitle = "RIVALS",
    Icon = "crosshair",
    ToggleKey = Enum.KeyCode.RightControl,   -- false to bind your own
    Size = 920,                              -- design width; the height is derived
})

Window:SetStatus("ready")

local Tab = Window:Tab({ Title = "Aim", Icon = "target" })
local Rage = Tab:GroupBox({ Title = "Rage", Desc = "tight angles, slow refresh" })

Rage:Toggle({
    Name = "Silent aim",
    Desc = "Bends the shot packet toward the target.",
    Default = false,
    Flag = "aim.silent",
    Callback = function(on) Flux:Notify({ Text = on and "on" or "off", Kind = "success" }) end,
})

Rage:Slider({ Name = "Field of view", Min = 0, Max = 120, Default = 65, Suffix = "°", Flag = "aim.fov" })
Rage:Dropdown({ Name = "Target part", Options = { "Head", "UpperTorso" }, Default = "Head", Flag = "aim.part" })
```

Every control returns a handle. A value-bearing one (`Toggle`, `Checkbox`, `Slider`, `Dropdown`,
`Input`, `Keybind`, `ColorPicker`, `Label`, `ProgressBar`) exposes the same surface:

| Member | Meaning |
| --- | --- |
| `Set(value)` | writes the value, repaints, fires the callback |
| `GetValue()` | reads the model, never the UI |
| `Changed` | signal fired on every value change |
| `SetVisible(bool)` | hides the row |
| `SetTitle(text)` | relabels, and re-registers it in the search index |
| `Destroy()` | removes the row, its search entry and its config binding |

`Button` acts instead of holding a value, so it has `SetCallback`, `SetText`, `SetIcon`,
`SetDisabled`, `SetVisible`, `Destroy`. `Paragraph` and `Divider` are inert: no signal and no
callback, because there is nothing to change.

Dot-calls and colon-calls are both accepted (`row:Set(v)` and `row.Set(nil, v)`), because a handle is
a table of methods and hosts write it either way.

---

## Components

Twelve ship in the index, so they exist on every container — a groupbox, a modal body, or a group you
register yourself:

**Acted on:** `Button`, `Toggle`, `Checkbox`, `Slider`, `Dropdown`, `Input`, `Keybind`, `ColorPicker`
**Read-only:** `Label`, `Paragraph`, `Divider`, `ProgressBar`

Common options: `Name` (also the search label), `Title` (the text shown, defaults to `Name`), `Desc`
(rendered under the label *and* used as the row's tooltip), `Flag` (config key), `Callback`.

Add a widget of your own without touching the library:

```lua
Flux:AddComponent("Gauge", require(workspace.Gauge))   -- { new = function(group, options, ctx) end }
local gauge = SomeGroup:Gauge({ Name = "fps" })
```

---

## Theming

Roles, not hex values: a widget asks for `Accent`, `Panel`, `TextMuted`, `Field`, `BorderPrimary`,
`Success`… and every instance bound to that role repaints when it changes.

```lua
Flux:SetTheme("Purple")                       -- Dark · Purple · Red · Blue · Custom
Flux:SetTheme({ Accent = Color3.new(1, .5, .2) })  -- one role, everything else untouched
local snapshot = Flux:GetTheme()              -- feed straight back into SetTheme to restore
Flux:OnThemeChanged(function() end)           -- returns an unsubscribe function
```

Icons are real artwork, not a font: 53 glyphs are embedded in the bundle, drawn as image labels and
tinted per role. On clients with a file API they are uploaded once and cached by name; without one
they render from the embedded data. An unknown name degrades to a plain glyph rather than a blank box.

---

## Config

Anything with a `Flag` is stored. Values live in the config system rather than in the widgets, so a
profile restores controls that have not been built yet — a tab the user never opened still comes back
with its saved values the moment it opens.

```lua
Flux:Save("legit")
Flux:Load("legit")
Flux:Config().names()         -- saved profile names
Flux:Config().available()     -- can this client write a file at all?
Flux:Config().export()        -- the profile as JSON text
Flux:Config().reset()         -- back to declared defaults
```

Files go to `FluxHub/Configs/<name>.json` through the usual executor globals (`writefile`,
`readfile`, `isfile`, `makefolder`, `listfiles`). Availability is probed rather than assumed, because
some clients define the names and then raise on every call. Without a working file API the profile
stays in memory for the session and `Save` reports failure instead of lying. `AutoSave` debounces
0.5 s after a change.

---

## Search

The header field filters across every window, not just the open tab. Matching is tiered — exact
label, prefix, contains, then subsequence, which is what makes `hnds` find `Headless` without letting
it outrank a real prefix.

A section is reached through its own title or description too: searching a word that only the card
knows opens the card *with its rows*, rather than showing an empty panel under the word you typed.

```lua
local hits = Flux:Search("silent")   -- number of matching entries
Flux:Search("")                      -- clear
```

---

## Notifications and tooltips

```lua
local note = Flux:Notify({
    Title = "Downloading",
    Text = "0 of 12 scripts",
    Kind = "info",          -- info · success · warning · error
    Icon = "download",      -- overrides the kind's glyph
    Progress = 0,           -- shows a track
    Duration = 6,           -- 0 / Persistent keeps it until dismissed
})

note:Update({ Text = "6 of 12 scripts", Progress = .5 })  -- re-times itself
note:Dismiss()
```

Tooltips are one shared surface, not one per row: a page with forty rows costs forty `MouseEnter`
connections and zero frames. It appears after a delay, hides immediately on leave, follows the
pointer, and is clamped inside the viewport so its edge is never off-screen. Passing `Desc` to any
control wires it up; `Flux:System("tooltip").configure({ Delay = .2 })` changes the timing.

---

## Keybinds

```lua
Group:Keybind({ Name = "Panic", Default = Enum.KeyCode.RightShift, Callback = function() end })
Group:Keybind({ Name = "Boost", Default = "E", Hold = true })    -- read a hold row with GetState()
Flux:Binds()                                                     -- everything the hub owns
```

Chords parse from a string (`"Shift+P"`) and store as one. A modifier bound on its own fires once,
not on every other key pressed — the library tracks which key a modifier state came from, so
`RightControl` as a toggle key does not light up a bind that only wants *some* control.

---

## Responsive and frame budget

Nothing in this library is built during the click that opens it.

- A declared tab is one pill. Its page — scrolling frame, two columns, cards — is built on first
  open, and each card mounts through a per-frame cost budget rather than in one parenting pass.
- `Tab:Defer(function(tab) … end)` moves a whole page's construction to that first open, for hosts
  whose controls are built in a loop.
- Breakpoints: under 760 px the page collapses to one column, under 560 px the chrome compacts.
  `Flux:System("layout").setMode("phone")` forces a layout; the window itself sizes from the one
  `Size` number it was given.
- Motion is hand-interpolated on one `RenderStepped` loop that only runs while something is moving,
  so `TweenService` being absent, stalled or overridden by another script cannot leave an element
  half-faded.

---

## Compatibility

Written for the clients scripts actually run on, not for a clean Studio place:

- No `TweenService`, no `ColorSequence` tricks, no `DescribeProperty`; every optional member is read
  through a guard (`GroupTransparency`, `AutoButtonColor`, the newer `UIStroke` fields) and the UI
  settles into a correct resting state when a member is missing.
- Rich text is escaped before it reaches a label, so a player name with `<` in it cannot break a row.
- `game.Name` is the *place* name and no in-client API gives a universe name, so the window never
  guesses; if you want the game's display name, pass it: `Window:SetSubtitle(name)`.
- The library keeps no globals and installs no engine hook. Unloading releases every connection,
  bind, notification and tooltip, and a second `loadstring` builds a fresh hub.

---

## Repository

```
src/            42 modules: Core (window/tab/groupbox/element), Components (12), Systems (11),
                Utilities (7), Assets (theme + icon atlas), init (bundle entry)
dist/FluxHub.lua  generated single-file bundle — this is what a script loads
example/        Showcase.lua: a whole hub written against the public API
tests/          headless harness (engine stub + TAP helpers) and 16 spec files
tools/          build, static gate, test runner, luau installer, icon generator
```

```bash
node tools/install-luau.mjs  # fetches .tools/luau.exe + luau-ast.exe (gitignored, needed to test)
node tools/build.mjs         # src -> dist/FluxHub.lua
node tools/check.mjs         # parses every module, caps function complexity
node tools/run-tests.mjs     # 16 specs, 1,920 assertions
node tools/run-tests.mjs --filter 12 --verbose
node tools/check-example.mjs # runs example/Showcase.lua against the stub
```

The suite runs on the official Luau CLI (pinned release `0.748`, linux/windows/macos archives);
`install-luau.mjs` re-downloads it after a clone, and the specs are green against a fresh copy of
those binaries.

`tests/harness/stub.lua` stands in for the engine: instances are tables with a property bag,
`RenderStepped` is a signal the specs fire by hand, and `task.delay` / `task.spawn` run on a fake
clock. That is what makes frame-budget, animation and lifetime assertions deterministic — and it is
also the limit of what is verified. **The suite proves behaviour, structure and release; it cannot
prove how the UI looks.** The layout numbers come from the design pass described in
[`docs/DESIGN.md`](docs/DESIGN.md),
and nothing here has been screenshotted from a running client.

## Status

- Version `0.1.0`, recorded in [`VERSION`](VERSION)
  and stamped into the bundle at build time, so `Flux.Version` cannot drift from the tag.
- No releases, no CI, no published raw URL yet: until the repo is pushed, `loadstring` the file
  contents or serve `dist/FluxHub.lua` yourself.
- No `LICENSE` file: without one, default copyright applies and nothing here is licensed for reuse,
  so pick a license before inviting others to fork it.
- Not built or tested against another library's API; the shape follows the hub style hosts already
  write (`Flux:Window`, `Window:Tab`, `Tab:GroupBox`, `group:Toggle`), deliberately.
