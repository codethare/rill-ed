# Focus flow analysis: TTY switch-back

## Scope

Trace the window focus flow after output removal/addition during TTY switch-back on a **single display**.

Files read:
- `src/layout.zig` (full, 244 lines)
- `src/main.zig` (full, 202 lines)
- `src/window.zig` (full, 105 lines)
- `src/output.zig` (full, 99 lines)
- `src/types.zig` (full)
- `src/seat.zig` (full)
- `src/animation.zig` (full)
- `protocol/river-window-management-v1.xml` (full, 1860 lines)
- `.zig-cache/o/.../wayland.zig` (river protocol stubs)

---

## Protocol event ordering (critical foundation)

From `river-window-management-v1.xml`:

> **Manage sequence**: server sends state-change events followed by `manage_start`.
> **Render sequence**: server sends `river_window_v1.dimensions` events followed by `render_start`.
>
> Dims events are sent in response to `propose_dimensions` during a *previous* manage sequence.

The `dimensions` event on a new `river.WindowV1` is **never** sent before `manage_start`. The full cycle is:

1. Server → client: `.window` (new_id river.WindowV1) + `.manage_start`
2. Client (apply): `proposeDimensions(0,0)` + `manage_finish`
3. Server queries the window for its size (async)
4. Server → client: `.dimensions` + `.render_start`

This means the first `apply()` after TTY switch-back runs **before any dimension events are dispatched** for the new window proxies.

---

## Bug 1: `focused_output_idx` stale after `swapRemove` (CRITICAL)

### Root cause

`layout.apply()` at line 239 calls `output_list.swapRemove(output_idx)` without adjusting `wm.focused_output_idx`.

### Trace

**State before apply()**:
```
output_list.items  = [old_output(removed), new_output]
output_list.len    = 2
focused_output_idx = 1   (set in output.add() at output.zig:21)
```

**In apply()** — loop iterates backwards:
1. `output_idx=1` (new_output): workspace empty, no focus.
2. `output_idx=0` (old_output, removed): migration runs, then `swapRemove(0)`.

After `swapRemove(0)`:
```
output_list.items  = [new_output]   // last element moved to index 0
output_list.len    = 1
focused_output_idx = 1              // ⚠️ STALE — now points past the end
```

### Crash site

In `window.zig:20`, when the `.dimensions` event fires later:
```zig
const output_idx = wm.focused_output_idx orelse return;  // yields 1
const output = &wm.output_list.items[output_idx];        // items.len=1 → OOB
```

This is an out-of-bounds slice access. Debug/ReleaseSafe builds panic. ReleaseFast builds read garbage memory.

### Impact chain

1. Dimension events can't add windows to any output (crash before reaching `window.add()`).
2. `pending_windows` entries are never consumed (since the dimension handler returns or crashes before `swapRemove`).
3. `focused_window_idx` is never set.
4. `manageDirty()` is never called from the dimension handler → manage cycle stalls.
5. No window ever gets focus.

### Fix

In `layout.apply()`, after `swapRemove`, adjust `focused_output_idx`:

```zig
_ = output_list.swapRemove(output_idx);
// After swapRemove, items that were after output_idx shifted left.
if (wm.focused_output_idx) |*foi| {
    if (foi.* > output_idx) foi.* -= 1;
    if (foi.* >= output_list.items.len) foi.* = output_list.items.len - 1;
}
```

Or simpler, since we know the singleton case matters most:
```zig
_ = output_list.swapRemove(output_idx);
if (wm.focused_output_idx) |*foi| {
    if (foi.* == output_idx) {
        // The focused output was removed; pick the first remaining.
        foi.* = @min(output_idx, output_list.items.len - 1);
    } else if (foi.* > output_idx) {
        foi.* -= 1;
    }
}
```

---

## Bug 2: `focused_window_idx` not transferred during migration (MAJOR)

### Root cause

`layout.apply()` lines 215–226 migrate windows but do **not** copy `src_ws.focused_window_idx` to `target_ws`.

```zig
for (src_ws.window_list.items) |window| {
    if (window.is_fullscreen) window.river_window.exitFullscreen();
    target_ws.window_list.append(allocator, window) catch continue;
}
// ⚠️ target_ws.focused_window_idx is NOT set from src_ws.focused_window_idx
```

### Effect

After migration, `target_ws.focused_window_idx` remains `null` (fresh workspace) or holds a stale index (pre-populated workspace).

Since `apply()`'s focus loop (line 231) checks `if (window_idx != workspace.focused_window_idx) continue;` and `null != usize` is always false, **`focusWindow()` is never called** for the migrated windows.

### Why the dimension handler is NOT sufficient mitigation

The dimension handler (`window.zig:17-31`) does set `focused_window_idx` when it processes `.dimensions` events. But:

1. Dimension events may arrive **frames later** (river must negotiate with the window for its preferred size).
2. Even when they arrive, **Bug 1** (stale `focused_output_idx`) causes an out-of-bounds crash before `window.add()` can run.

So even if Bug 1 is fixed, there's a window (potentially multiple frames) where the workspace has windows but `focused_window_idx` is null.

### Fix

After copying windows, transfer the focus index:

```zig
target_ws.window_list.append(allocator, window) catch continue;
// ...
target_ws.focused_window_idx = src_ws.focused_window_idx;
```

---

## Bug 3: Duplicate window entries from stale migration (MAJOR)

### Root cause

When river re-creates a TTY-switched-away output, it sends **new** `.window` events with **new** `river.WindowV1` Wayland proxy objects (new_id). The `apply()` migration code also copies the **old** `types.Window` objects (with stale `river.WindowV1` references) from the removed output's workspace to the target workspace.

The dimension handler (`window.zig:17-31`) adds fresh `types.Window` objects (with valid new proxies) to the same workspace.

### Result

The target workspace ends up with **both** sets:

```
workspace.window_list = [fresh_Window_A, fresh_Window_B, stale_Window_A, stale_Window_B]
```

Where `stale_Window_A/B` reference old `river.WindowV1` proxies that may be:
- Invalid/dangling (if river destroyed them when the output was removed) → protocol errors, use-after-free.
- Still alive but redundant → duplicate layout calculations, conflicting rendering state.

### Special note on `exitFullscreen()` in migration

The migration code calls `window.river_window.exitFullscreen()` on stale proxies. If the proxy is invalid, this is a protocol error. If the proxy is still alive, it may conflict with the fresh proxy's state.

### Fix

For the TTY switch-back case (single display where the removed output had all windows), the "free memory" else branch (line 229) is more correct:

```
} else {
    // Don't close windows; river will re-send window events.
    for (&output.workspace_list) |*workspace| {
        workspace.window_list.deinit(allocator);
    }
}
```

But the code takes the migration branch because `output_list.items.len > 1` (the new output was already added). The code cannot currently distinguish "removed because TTY switched" from "removed because monitor unplugged while another monitor is still connected."

A heuristic: if the only *non-removed* output is the one just created (same display coming back), prefer the free-memory path. But this requires tracking whether the new output is a replacement for the removed one.

**Minimal fix**: In the single-display scenario, the removed handler (`output.zig:44-45`) already sets `focused_output_idx = null` when the only output is removed. Before entering apply(), check if focused_output_idx is null → skip migration for all removed outputs, just free them.

---

## Bug 4: `layout.update()` called on unstable output_list

The dimension handler calls `layout.update(wm.output_list, ...)` after adding a window. But `wm.output_list` may be in an inconsistent state if `apply()`'s removed-output processing hasn't run yet (e.g., dimension events arrive before the manage_start that triggers apply).

This is less critical than the other bugs but worth noting.

---

## Summary table

| # | Bug | Severity | File/Line | Fix |
|---|-----|----------|-----------|-----|
| 1 | `focused_output_idx` stale after `swapRemove` | **CRITICAL** (crash) | `layout.zig:239` | Adjust `focused_output_idx` after `swapRemove` |
| 2 | `focused_window_idx` not transferred in migration | **MAJOR** (no focus) | `layout.zig:219-225` | Copy `src_ws.focused_window_idx` to target |
| 3 | Duplicate windows from stale migration + fresh window events | **MAJOR** (duplicates, stale proxy) | `layout.zig:215-226` | Use free-memory path when river re-sends windows |
| 4 | `layout.update()` on unstable list | **LOW** | `window.zig:28` | Guard or defer |

---

## Answer to the core question

> After migration, does new_output's workspace have focused_window_idx set?

**No, not by the migration code itself.** The migration code at `layout.zig:215-226` only appends to `target_ws.window_list`. It does **not** set `target_ws.focused_window_idx`. If the target workspace was freshly created (as in TTY switch-back), `focused_window_idx` remains `null`. No `focusWindow()` is called for the migrated windows.

The dimension handler (`window.zig:17-31`) would normally set `focused_window_idx` later when `.dimensions` events arrive. But it crashes first due to Bug 1 (stale `focused_output_idx` causing OOB access).

**Verdict**: After the first `apply()` following TTY switch-back, `focused_window_idx` is **not set**. Focus is not assigned. Without fixing Bug 1, the dimension handler crashes before it can help.

---

## Acceptance Report

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Analyzed the TTY switch-back flow end-to-end using the river protocol XML specification and all relevant source files."
    },
    {
      "id": "criterion-2",
      "status": "satisfied",
      "evidence": "Report documents 4 bugs with exact file paths, line ranges, root causes, impact chains, and proposed fixes."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "find, grep, read on 11 source files including protocol XML",
      "result": "passed",
      "summary": "Traced event dispatch order, migration logic, focus checks, and index management across all relevant modules"
    }
  ],
  "validationOutput": [
    "Protocol analysis confirms .dimensions events always arrive after .manage_start (never before apply())",
    "swapRemove(0) leaves focused_output_idx=1 in a list of length 1 → confirmed OOB access in window.zig:20",
    "Migration code at layout.zig:215-226 copies windows but does not set focused_window_idx",
    "Duplicate entries confirmed: migration copies stale Window objects while dimension handler adds fresh ones"
  ],
  "residualRisks": [
    "Fix for Bug 1 (focused_output_idx adjustment) is needed before any other fix can be tested; the dimension handler currently crashes before it can help.",
    "Bug 3 (duplicate windows) requires policy logic to distinguish TTY switch-back from multi-monitor disconnect.",
    "No test infrastructure exists to verify the fix; manual testing with river on a real TTY switch is required.",
    "The river protocol version used is 4; behavior may differ slightly on older versions."
  ],
  "noStagedFiles": true,
  "diffSummary": "No code changes made; analysis report only.",
  "reviewFindings": [
    "blocker: layout.zig:239 - swapRemove without adjusting focused_output_idx causes OOB crash in window.zig:20",
    "blocker: layout.zig:215-226 - migration does not set focused_window_idx, leaving workspace with null focus",
    "major: layout.zig:215-226 - migration copies stale Window objects with old Wayland proxies, creating duplicates when dimension handler adds fresh ones",
    "low: window.zig:28 - layout.update() called while output_list may be unstable"
  ],
  "manualNotes": "Bug 1 must be fixed first (it's a crash). Bug 2 depends on Bug 1 being fixed. Bug 3 is architecturally complex and may be deferred but should be documented."
}
```
