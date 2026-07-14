# Architecture & Maintainability Analysis: rill-ed

## Summary

rill-ed is a small (~2,700 LOC), single-binary Wayland client that implements a scrolling window manager on top of the river compositor. It is intentionally compact, but the compactness is achieved by packing most global state and type definitions into one file (`src/types.zig`) and routing most event-driven logic through one global `WindowManager` instance. This analysis identifies the architectural friction points that will slow down future changes and the smallest, lowest-risk ways to reduce them.

## Module dependency map

```
main.zig
├── animation.zig
├── config.zig
├── keybinding.zig
│   ├── config.zig
│   ├── layout.zig
│   ├── overview.zig
│   └── spawn.zig
├── layout.zig
│   ├── layout/common.zig
│   ├── layout/scroller.zig
│   └── layout/floating.zig
├── output.zig
│   └── layout.zig
├── overview.zig
│   ├── layout.zig
│   └── layout/common.zig
├── seat.zig
│   ├── layout.zig
│   └── overview.zig
├── spawn.zig
├── window.zig
│   └── layout.zig
└── types.zig  <-- imported by *every* module
```

`types.zig` is the hub: every module imports it. That is fine for a project of this size, but `types.zig` is not only data types — it also contains the full default keybinding/pointer-binding tables and `Color.toRiverColor()`. In practice it is a mixed-purpose file.

## Findings

### 1. `src/types.zig:1-277` — COUPLING — `types.zig` has become a "catch-all" module
- **Description**: `types.zig` defines `WindowManager`, `Window`, `Workspace`, `Output`, `Rectangle`, `Status`, `OverviewState`, `Config`, `Border`, `Color`, and the complete `default_keybindings` / `default_pointer_bindings` tables. It also re-exports `actions.zig`.
- **Impact**: Any change to a default keybinding, a color, or an action name recompiles every module. More importantly, the file couples *application data model* with *default UI policy*, making it harder to locate where behavior lives.
- **Improvement direction**: Move `default_keybindings`/`default_pointer_bindings` into `keybinding.zig` (they are binding policy, not core types) and move `Color.toRiverColor()` into `layout.zig` or `animation.zig` (it is rendering conversion). Keep `types.zig` focused on the data model: `WindowManager`, `Window`, `Workspace`, `Output`, `Rectangle`, `Status`, `Config`.

### 2. `src/types.zig:19-44` — DESIGN — `WindowManager` is a global singleton accessed by import
- **Description**: `main()` creates one `WindowManager` on the stack and passes a pointer to every Wayland listener. Every module imports `types` and manipulates the same struct fields. There is no secondary constructor or test factory.
- **Impact**: Unit testing any function that takes `*WindowManager` requires building a fully populated `WindowManager` with real Wayland objects, which is impractical. The singleton also makes it impossible to run two independent WM states in the same process.
- **Improvement direction**: This is acceptable for a single-client WM, but extract pure helper functions that operate on `[]Output`, `Workspace`, `Config`, etc., so the layout/scrolling logic can be tested without a full `WindowManager`. Example candidates: `layout.zig:update`, `animation.zig:apply`, `layout/scroller.zig:apply`, `layout/common.zig:{initialRectangle,centerRectangle}`.

### 3. `src/main.zig:93-161` — COUPLING — `windowManagerListener` aggregates unrelated concerns
- **Description**: `windowManagerListener` handles output creation, seat setup, pending-window registration, manage/render lifecycle, and the `finished` event in a single 70-line switch.
- **Impact**: Adding a new top-level protocol event means editing `main.zig`, even if the logic belongs to `output.zig`, `seat.zig`, or `window.zig`.
- **Improvement direction**: Keep the top-level dispatch in `main.zig` but delegate each branch to the owning module, e.g. `output.handleOutputEvent(...)`, `seat.handleSeatEvent(...)`. This is a small refactor that preserves the current event flow.

### 4. `src/layout.zig:14` — DESIGN — global mutable `pending_windows`
- **Description**: `pub var pending_windows: std.ArrayList(*river.WindowV1) = .empty;` is module-level mutable state. It is freed in `main.zig` via `defer layout.pending_windows.deinit(...)`.
- **Impact**: Hidden global state makes it impossible to test `layout.apply()` deterministically without manually initializing/freeing this global. It also creates a circular dependency smell: `window.zig` imports `layout.zig` to remove items from `pending_windows`.
- **Improvement direction**: Move `pending_windows` into `WindowManager` so it is owned by the singleton state and automatically cleaned up in `WindowManager.deinit()`. Then `layout.apply(wm, ...)` reads `wm.pending_windows`.

### 5. `src/types.zig:42` — DESIGN — `getConfig()` returns a value copy of `Config`
- **Description**: `pub fn getConfig(self: *WindowManager) Config { return self.config.*; }` returns the whole `Config` struct by value. The struct contains slices (`spawn_at_startup`, `keybindings`, `pointer_bindings`), so the copy is cheap (pointer + len), but the call site pattern is inconsistent.
- **Impact**: Callers receive an owned copy and cannot modify the config. This is safe, but every hot path (layout, animation, keybinding dispatch) pays a struct copy. In a ~2,700 LOC WM this is negligible, but the API signature obscures whether the caller should mutate config.
- **Improvement direction**: Return `*const Config` instead. It removes the copy, makes immutability explicit, and avoids accidental future mutation attempts. This is a one-line change with a small ripple through the codebase.

### 6. `src/config.zig:11-23` — DESIGN/ERROR_HANDLING — `load()` silently falls back to defaults
- **Description**: `load()` prints `std.debug.print` on failure and returns a heap-allocated default config. `reload()` silently returns `null` and keeps the old config if no file exists.
- **Impact**: Users with a typo in their config path get no visible error at runtime (only stderr), and may not realize they are running defaults. `reload()` returning `null` is fine, but the loader returning defaults on *any* parse error is permissive.
- **Improvement direction**: Distinguish "file not found" (fallback OK) from "parse error" (log loudly and keep old config). The current code already returns `error.FileNotFound` for missing env vars; propagate parse errors explicitly instead of falling back to defaults.

### 7. `src/config.zig:1-77` — TESTING — config preprocessing is mentioned but not implemented
- **Description**: README mentions `// @if(hostname=...)` and `// @include(file)` directives, but `config.zig` contains no preprocessing logic. `load()` reads the raw file and passes it directly to `std.zon.parse.fromSliceAlloc`.
- **Impact**: The feature either does not exist or is implemented elsewhere (not in this tree). If it does not exist, the README is misleading. If it is planned, adding it later will require touching the same file.
- **Improvement direction**: Either remove the README claim or implement a minimal preprocessor before ZON parsing. If implemented, keep it in a separate file (`config/preprocess.zig`) so `load()` stays readable.

### 8. `src/types.zig:46-67` — DESIGN — `WindowManager.deinit()` owns cleanup for all sub-allocations
- **Description**: `deinit()` frees `config`, `overview_state.origins`, binding lists, all workspace window lists, the output list, and finally destroys the registry. This is correct but relies on every other module *not* freeing these arrays elsewhere.
- **Impact**: It is easy to introduce a double-free or leak by adding a new ArrayList field to `WindowManager` and forgetting to add it to `deinit()`.
- **Improvement direction**: After moving `pending_windows` into `WindowManager`, centralize ownership is actually the right pattern — just document it: "All `std.ArrayList` fields in `WindowManager` are freed in `deinit()`; modules must not free them independently." Add an assertion-style test that every `ArrayList`/slice field is accounted for.

### 9. `src/keybinding.zig:94-530` — DESIGN — `keybindingPressed()` is a 436-line action dispatcher
- **Description**: `keybindingPressed()` contains the entire user-action state machine. It mutates `wm` directly, calls `moveWindowToWorkspace`, `layout.update`, `spawn.spawnDetached`, `overview.enter`, and `config.reload`.
- **Impact**: The function is large enough that reviewers cannot easily verify all state transitions. Adding a new action requires editing this file and `actions.zig`.
- **Improvement direction**: Split into per-action helpers grouped by category (window, workspace, output, session). Keep the `switch` as a thin dispatcher. This is a refactor with no behavior change.

### 10. `src/keybinding.zig:497-505` — DESIGN — `reload_config` action mixes policy with execution
- **Description**: On `.reload_config`, the action directly calls `config.reload()`, sets the cursor theme, calls `layout.update`, and transitions to `.setup_bindings`.
- **Impact**: The action knows too much about config internals and binding lifecycle. If config reload semantics change, two modules must be edited.
- **Improvement direction**: Introduce a small `config.applyReload(wm)` helper that encapsulates the reload, cursor update, and binding refresh request. `keybindingPressed` just calls it.

### 11. `src/layout.zig:31-155` — DESIGN — `layout.apply()` mixes migration, cleanup, border rendering, and focus
- **Description**: `apply()` removes dead outputs, migrates/detaches windows, recomputes borders, handles fullscreen exits, closes windows, sets layer-shell defaults, and focuses the selected window. It is 125 lines of tightly coupled logic.
- **Impact**: The function is hard to unit test and easy to break when changing one aspect (e.g., focus) without affecting others. Existing bug fixes (e.g., `focused_output_idx` adjustment after `swapRemove`) live here.
- **Improvement direction**: Decompose into phases:
  1. `processRemovedOutputs()`
  2. `applyPendingWindows()`
  3. `renderFrame(wm, river_seat)`
  4. `applyFocus(wm, river_seat)`
  Functions can remain file-private; the public `apply()` just calls them in order.

### 12. `src/animation.zig:5-95` — TESTING — animation interpolation is pure and easily testable
- **Description**: `animation.apply()` takes `output_list`, `focused_output_idx`, `config`, `start_time`, and `now` and returns a `Status`. It does not touch Wayland state except through `placeWindow()`.
- **Impact**: This is the most testable module in the project. Currently it has no tests.
- **Improvement direction**: Add a test that creates a fake `Output` with one `Window`, sets `start`/`finish`, calls `apply()` with `now = start_time + duration / 2`, and checks that `window.current` is between `start` and `finish`.

### 13. `src/layout/common.zig:15-37` — TESTING — rectangle math is also easily testable
- **Description**: `initialRectangle()` and `centerRectangle()` are pure functions of `Rectangle` and `Config`.
- **Impact**: No tests exist. A regression in gap math would affect every new window.
- **Improvement direction**: Add tests for these two functions first; they require no Wayland mocks.

### 14. `src/main.zig:161-228` — DESIGN — `manage()` is the global state-machine coordinator
- **Description**: `manage()` dispatches on `wm.status` and calls the appropriate module. It handles `.layout`, `.animation`, `.overview`, `.pointer_action`, `.setup_bindings`, `.exit`, and `.none`.
- **Impact**: This is the single most important coordination function. It is readable, but a few transitions (e.g., `.setup_bindings` requesting `manageDirty()` immediately after setup) are subtle.
- **Improvement direction**: Keep `manage()` as is, but add a state-transition test: construct a `WindowManager` with mocked status values and verify the correct next status is produced. To enable this, split the status transition logic from the Wayland side effects.

### 15. `src/output.zig:10-44` — COUPLING — `output.add()` restores detached workspaces and triggers `manageDirty()`
- **Description**: Adding an output restores `detached_workspaces` if present and immediately requests a manage cycle.
- **Impact**: Output creation has hidden side effects on global state (`wm.status`, `focused_output_idx`).
- **Improvement direction**: Move the restore logic to `layout.apply()` or a dedicated `lifecycle.zig` module so `output.add()` only creates the output record. This makes TTY switch-back behavior easier to reason about (and test).

### 16. `src/seat.zig:11-106` — COUPLING — `seatListener` assumes the clicked window is in the focused workspace
- **Description**: The listener fetches the focused window first, then searches all outputs for the clicked window. If not found, it returns silently.
- **Impact**: The function has implicit assumptions about focus consistency. If `wm.focused_output_idx` is stale, the early lookup can panic on OOB.
- **Improvement direction**: Add a guard at the top of `window_interaction` that validates `output_idx` against `output_list.items.len`. This is a one-line defensive check that does not change behavior in valid states.

### 17. `src/window.zig:10-75` — DESIGN — `windowListener` duplicates window-search logic
- **Description**: `windowListener` has two nested search loops: one for `.dimensions` against `layout.pending_windows`, and one for other events against all workspaces.
- **Impact**: The search is O(outputs × workspaces × windows) for every event. With 10 workspaces and typical window counts this is fine, but the duplicated pattern is error-prone.
- **Improvement direction**: Add a helper `findWindowByRiverWindow(river_window) -> ?struct { output, workspace, idx }`. Use it in both paths. This also centralizes OOB guards.

### 18. `src/spawn.zig:7-73` — ERROR_HANDLING — `spawnDetached` uses `std.debug.print` for all errors
- **Description**: Empty argv, allocation failures, fork failures, and exec failures all print and return silently.
- **Impact**: A failed startup program gives no persistent feedback to the user or to tests.
- **Improvement direction**: Return `?std.process.Child.Error` (or log through a callback) so callers can decide whether to surface the error. For `spawn_at_startup`, logging is acceptable; for keybinding-spawned programs, a visible notification may be desirable later.

### 19. `src/overview.zig:12-97` — DESIGN — overview temporarily mutates workspace layout state
- **Description**: `overview.enter()` moves all windows into workspace 0, sets it to floating layout, and records origins. `cancel()`/`select()` restore them.
- **Impact**: If `overview.enter()` fails mid-way (e.g., OOM during `origins.append`), the workspace state is partially mutated. There is no rollback.
- **Improvement direction**: Pre-allocate `origins` to `total` (using `try origins.ensureTotalCapacity(allocator, total)`) before mutating workspaces, or perform a two-phase move: first record origins, then move windows after allocation succeeds.

### 20. `src/types.zig:38` — DESIGN — `detached_workspaces` is `?[10]Workspace`
- **Description**: When the last output is removed, the 10 workspaces are preserved as a value copy inside `WindowManager`. The windows inside keep their `river_window` pointers.
- **Impact**: This is an architectural "save game" for TTY switch-back. It is clever but adds a special-case lifetime that does not follow normal output/workspace rules.
- **Improvement direction**: Document the invariant: `detached_workspaces` is only non-null when `output_list` is empty. Consider extracting this into `lifecycle.detachWorkspaces()` / `lifecycle.restoreWorkspaces()` helpers.

## Top 3 minimal maintainability improvements

### 1. Return `*const Config` from `WindowManager.getConfig()`
- **File**: `src/types.zig:42`
- **Change**: Replace `pub fn getConfig(self: *WindowManager) Config` with `pub fn getConfig(self: *WindowManager) *const Config`.
- **Ripple**: Update all call sites that take `Config` to take `*const Config` or `types.Config` by value where mutation is not needed (`layout.zig`, `animation.zig`, `output.zig`, `seat.zig`, `window.zig`, `keybinding.zig`, `overview.zig`).
- **Benefit**: Removes hidden struct copies, makes immutability explicit, and is a pure refactor.

### 2. Move `pending_windows` from `layout.zig` global into `WindowManager`
- **Files**: `src/types.zig:40`, `src/layout.zig:14`, `src/main.zig:67`, `src/window.zig:18-30`
- **Change**: Add `pending_windows: std.ArrayList(*river.WindowV1) = .empty` to `WindowManager`, remove the global `pub var`, update references to `wm.pending_windows`, and free it in `WindowManager.deinit()`.
- **Benefit**: State ownership becomes explicit, `layout.apply()` no longer relies on hidden global state, and tests can construct a complete `WindowManager` without touching module globals.

### 3. Add tests for pure geometry functions before touching layout logic
- **Files**: `src/layout/common.zig`, `src/animation.zig`, `src/layout/scroller.zig`
- **Change**: Add small tests for `initialRectangle`, `centerRectangle`, and `animation.apply` using hand-built `Rectangle`/`Window`/`Output` values. No Wayland mocks needed.
- **Benefit**: Creates a safety net for future layout refactors. Since layout bugs have already been identified (`focused_output_idx` after `swapRemove`), having regression tests for the geometry core reduces the chance of reintroducing similar issues.
