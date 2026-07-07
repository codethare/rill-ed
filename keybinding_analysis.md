# Keybinding Lifecycle Across TTY Switch

## Files Examined

1. `src/keybinding.zig` (full) — `setupKeybindings()`, `xkbBindingListener()`, keybinding action dispatch
2. `src/main.zig` (full) — event loop, `windowManagerListener()`, `manage()` state machine
3. `src/output.zig` (full) — `add()`, `outputListener()` (`.removed` event handler)
4. `src/seat.zig` (full) — `seatListener()`, `setupPointerBindings()`
5. `src/types.zig` (full) — `WindowManager`, `Status`, `Output` struct definitions
6. `src/animation.zig` (full) — animation state machine iteration
7. `src/layout.zig` (full) — `apply()` with TTY-switch‑aware output removal logic
8. `protocol/river-window-management-v1.xml` — `.seat` event definition, `river_seat_v1.removed`
9. `protocol/river-xkb-bindings-v1.xml` — `get_xkb_binding` request, `river_xkb_binding_v1` lifecycle
10. `river/river/Seat.zig` — `manageStart()`, `makeInert()`, `handleDestroy()` (bindings lifecycle)
11. `river/river/XkbBinding.zig` — `create()`, `destroy()`, `match()` (binding persistence)
12. `river/river/XkbBindingsSeat.zig` — `manageStart()`, `makeInert()`
13. `river/river/Output.zig` — `manageStart()` output event creation logic
14. `river/river/WindowManager.zig` — manage sequence, seat/output event emission
15. `river/river/KeyboardGroup.zig` — VT switch handling via `session.changeVt()`

---

## Architecture

### Startup flow
```
wl_registry.global (river_window_manager_v1) → registryListener binds it
river_window_manager_v1.seat                 → windowManagerListener:
                                                wm.river_seat = seat
                                                wm.status = .setup_bindings
manage_start                                 → manage():
                                                .setup_bindings → setupKeybindings()
                                                                  setupPointerBindings()
                                                                  wm.status = .layout
                                                .layout         → layout.apply()
manage_finish
```

### Normal manage cycle
```
manage_start → manage():
                .layout  → layout.apply() → wm.status = .animation
                .animation → animation.apply() → wm.status = .none | .animation
                .none    → river_seat.opEnd()
manage_finish
```

### `setupKeybindings()` lifecycle
```zig
// Called only when wm.status == .setup_bindings
pub fn setupKeybindings(allocator: Allocator, wm: *types.WindowManager) !void {
    for (wm.xkb_binding_list.items) |binding| binding.river_xkb_binding.destroy();
    wm.xkb_binding_list.clearRetainingCapacity();   // ← destroys old, creates new
    for (wm.getConfig().keybindings) |keybinding| {
        const xkb_binding = try xkb_bindings.getXkbBinding(
            wm.river_seat.?,
            @intFromEnum(keysym),
            keybinding.modifiers,
        );
        xkb_binding.setListener(…);
        xkb_binding.enable();
    }
}
```

`wm.status` is set to `.setup_bindings` in exactly **two** places:
1. `windowManagerListener` `.seat` event branch (line 162 of `main.zig`)
2. `keybindingPressed()` `.reload_config` action branch (line 203 of `keybinding.zig`)

---

## TTY Switch — What Actually Happens

### river side (confirmed from river source)

**VT switch-out** (user presses Ctrl+Alt+F2):
- River's `KeyboardGroup` handles `XF86Switch_VT_2` keysym
- Calls `server.session.changeVt(2)` (KeyboardGroup.zig:395-398)
- wlroots' DRM backend drops DRM master
- All `wlr_output` objects emit `.destroy` → `Output.handleDestroy()` marks state as `.destroying`
- **Seat is NOT destroyed.** `wlr_seat` persists (it's a long‑lived server object, not tied to DRM master)
- **`Seat.makeInert()` is NOT called.** `seat.object` remains non‑null.

**VT switch-back** (user presses Ctrl+Alt+F1 or compositor's VT):
- wlroots' DRM backend regains DRM master
- New `wlr_output` objects are created → `Output.create()` (Output.zig:184)
- `Output.create()` calls `server.wm.dirtyWindowing()` → triggers manage sequence

**During manage sequence:**
1. `Output.manageStart()` runs for each output:
   ```zig
   if (server.wm.object) |wm_v1| {
       const new = output.object == null;    // ← true for new outputs
       const output_v1 = output.object orelse blk: {
           // creates new river_output_v1, sends wm_v1.sendOutput(output_v1)
           // → rill receives .output event
   ```
2. `Seat.manageStart()` runs:
   ```zig
   if (server.wm.object) |wm_v1| {
       const new = seat.object == null;      // ← FALSE: seat.object is still set!
       // No new river_seat_v1 created, no sendSeat() called
       // → rill receives NO .seat event
   ```
3. `wm_v1.sendManageStart()` → rill's `manage()` is called

### rill side

**VT switch-out:**
1. Each output receives `.removed` → `outputListener`:
   - `output.is_removed = true`
   - `wm.status = .layout`
   - If last output (`len == 1`): `wm.focused_output_idx = null`
2. `.manage_start` → `manage()`:
   - If `focused_output_idx` is null: returns early (correct for single‑output)
   - `layout.apply()` removes `is_removed` outputs, frees/migrates windows
3. Seat events are NOT received (no `.removed` on seat because seat was not destroyed)

**VT switch-back:**
1. New `.output` events → `output.add()`:
   - Appends output to `wm.output_list`
   - `wm.focused_output_idx = wm.output_list.items.len - 1`
   - Sets listener for further events (dimensions, position, non_exclusive_area)
2. Output dimension/position events → rectangle updates, `wm.status = .layout`
3. Window events (`.window`) → pending windows queued, `wm.status = .layout`
4. **No `.seat` event** → `wm.status` stays at `.layout`, never `.setup_bindings`
5. `.manage_start` → `manage()`:
   - status = `.layout` → `layout.apply()` → sets `.animation`
6. Keybindings: the old `wm.xkb_binding_list` is still intact, `xkbBindingListener` works

---

## Key Question Answers

### Q1: Does TTY switch‑back trigger a `.seat` event?

**No.** River's `Seat` struct (with its `wlr_seat`) persists across VT switches. `seat.object` stays non‑null, so `Seat.manageStart()` does not create a new `river_seat_v1` and does not call `wm_v1.sendSeat()`. Only outputs are re‑created (new `.output` events).

### Q2: Are old xkb bindings still valid after TTY switch‑back?

**Yes.** On the server side:
- `XkbBinding` objects are stored in `Seat.xkb_bindings` (river/river/XkbBinding.zig)
- They persist until explicitly destroyed (via client `destroy()` request) or the seat is destroyed
- The seat is NOT destroyed during VT switch, so bindings survive
- The `match()` function uses xkb state (keymap + modifiers) to translate keycodes to keysyms; this state also persists across VT switches (libinput devices persist)

On the client (rill) side:
- `wm.xkb_binding_list` is untouched (since `setupKeybindings()` is never called)
- `wm.river_seat` still points to the original (valid) `river_seat_v1` object
- `xkbBindingListener()` continues to work

### Q3: Could `setupKeybindings()` at the start destroying old bindings break things?

This is only called when `wm.status == .setup_bindings`, which happens either:
1. In response to a `.seat` event (not sent on TTY switch‑back)
2. On `reload_config` (user‑initiated)

Since neither triggers during a normal TTY switch cycle, **the destroy loop is never entered during TTY switch**, so there is no risk of destroying active bindings mid‑operation. Even if it were called, the Wayland protocol guarantees that `destroy()` on a protocol object is safe (server handles cleanup).

### Q4: Does keyboard input break?

**No.** The full path remains functional:
```
key press → compositor matches keysym+modifiers against registered XkbBinding objects
         → sends .pressed on river_xkb_binding_v1
         → rill's xkbBindingListener() receives it
         → looks up in wm.xkb_binding_list (still populated)
         → dispatches keybindingPressed()
```

---

## Risks and Issues Found

### 1. Stale `focused_output_idx` in multi‑output all‑removed scenario

When **multiple** outputs are all removed simultaneously (e.g., TTY switch with 2+ outputs):

```zig
// outputListener .removed event handler (output.zig:37-55)
if (wm.output_list.items.len == 1) {          // len is still original count!
    wm.focused_output_idx = null;
}
```

The `len == 1` check looks at the **total** list length, not the count of non‑removed outputs. Since outputs remain in the list until `layout.apply()` cleans them up, this branch never fires for the last output when there were initially ≥2 outputs. Result: `focused_output_idx` stays set to a stale index (e.g., 0 or 1) while the list is empty or has only removed entries.

**Impact:** If a keybinding is pressed during the window between all outputs being removed and new ones appearing (which on TTY switch is practically zero since the TTY is away), `keybindingPressed()` does `wm.output_list.items[stale_idx]` which is an **out‑of‑bounds array access** → crash.

**Real‑world likelihood:** Near zero during TTY switch (user is on another VT, can't press keys). Could trigger on hot‑unplug of all GPUs. Single‑output setups (the common case) are unaffected because `len == 1` correctly fires.

**Fix:** Use a counter of non‑removed outputs, or nullify `focused_output_idx` in `layout.apply()` when the last output is removed.

### 2. Ignored `river_seat_v1.removed` event

```zig
// seat.zig seatListener
switch (event) {
    .window_interaction => …,
    .op_delta => …,
    .op_release => …,
    else => {},    // ← .removed silently dropped
}
```

If river ever DID send `.removed` (e.g., seat hot‑unplug), rill would keep a dangling `wm.river_seat` pointer. However, this does NOT occur during TTY switch.

### 3. Ignored `session_locked` / `session_unlocked` events

```zig
// main.zig windowManagerListener
else => {},   // ← session_locked/unlocked silently dropped
```

These are sent by river's `LockManager` (ext‑session‑lock protocol). Rill ignores them but that's harmless — they don't affect keybinding state.

### 4. `layout.apply()` calls `river_seat.clearFocus()` and `river_seat.focusWindow()` every manage cycle

```zig
// layout.zig:118-119
river_seat.clearFocus();
// …
river_seat.focusWindow(window.river_window);
```

These use `wm.river_seat` which is set only in the `.seat` event handler. If the seat were somehow stale, this would be a problem — but it's not stale during TTY switch.

---

## Summary

| Aspect | Finding |
|--------|---------|
| `.seat` event on TTY switch‑back | **Not sent.** River's seat persists across VT switches. |
| `setupKeybindings()` called on TTY switch‑back | **No.** It only runs on `.seat` event or `reload_config`. |
| Old `xkb_binding_list` entries | **Survive intact** on both client and server. |
| Keyboard input after TTY switch‑back | **Works.** Binding objects are still valid. |
| `destroy()` + `clearRetainingCapacity` risk | **No risk** — that code path is not entered during TTY switch. |
| Multi‑output `focused_output_idx` stale bug | **True** but benign in practice for TTY switch. |
| Overall verdict | **No xkb binding breakage on TTY switch.** The current code handles it correctly for the single‑output case. |

---

## Acceptance Report

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Investigated rill's keybinding lifecycle across TTY switch by reading all relevant source files (keybinding.zig, main.zig, output.zig, seat.zig, types.zig, layout.zig, animation.zig) and river's compositor source (Seat.zig, XkbBinding.zig, XkbBindingsSeat.zig, Output.zig, WindowManager.zig, KeyboardGroup.zig, Server.zig) plus protocol XML definitions. Traced the full event flow on both VT switch-out and switch-back, verified that river does NOT send a .seat event on TTY switch-back, confirmed old xkb bindings survive because the seat persists, and identified one related bug (stale focused_output_idx in multi-output all-removed scenario)."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "grep/search across src/ and river/river/ for VT, session, seat, binding lifecycle",
      "result": "passed",
      "summary": "Located all relevant event handlers, manageStart/makeInert/handleDestroy logic, and VT switch code path"
    }
  ],
  "validationOutput": [
    "Confirmed: river's Seat.makeInert() is NOT called during VT switch (only on WM disconnect or seat destruction)",
    "Confirmed: seat.object stays non-null across VT switch, so no new .seat event is emitted",
    "Confirmed: XkbBinding objects persist in seat.xkb_bindings list across VT switch",
    "Confirmed: setupKeybindings() is only called on .seat event or reload_config",
    "Found: stale focused_output_idx bug in multi-output all-removed case (output.zig .removed handler uses total list length, not non-removed count)"
  ],
  "residualRisks": [
    "Stale focused_output_idx in multi-output all-removed scenario could cause out-of-bounds access if a keybinding fires during the window with no outputs. Practically unreachable during TTY switch (user is on another VT), but could trigger on GPU hot-unplug."
  ],
  "noStagedFiles": true,
  "diffSummary": "No code changes — this is an analysis-only task.",
  "reviewFindings": [
    "no-blockers: keybinding lifecycle is safe across TTY switch for single-output (common case)",
    "minor: multi-output focused_output_idx stale after all outputs removed (output.zig:37-55)",
    "minor: river_seat_v1.removed event silently ignored in seat.zig seatListener (else => {})",
    "info: session_locked/unlocked events silently ignored in main.zig windowManagerListener (else => {})"
  ],
  "manualNotes": "The analysis was performed by reading both rill's source and river's compositor source (in ../river/). The river source confirms that seats are NOT destroyed/recreated on VT switch; only outputs are. This is the core reason why no .seat event is sent and why old xkb bindings remain valid."
}
```
