# Overview 键盘控制方案报告

## 问题诊断

### 1. 所有方向键在 overview 下无响应（根本原因）

**根本原因：缺少 `wmgr.manageDirty()` 调用**

`overviewKeyPressed` 设置 `wm.status = .overview` 后，没有调用 `wmgr.manageDirty()`。没有这个调用，compositor 不会发起新的 manage cycle → `manage()` 永远不会被调用 → `.overview` 分支（`overview.applyBorders`）永远不会执行 → 边框不重绘。

**证据链：**
- `overview.enter()` 末尾调了 `wmgr.manageDirty()` → 进入概览能正常显示
- `keybindingPressed` 的 `.enter_overview` 分支也调了 `wmgr.manageDirty()` → 同上
- 主循环只在 `wm.status == .animation` 时调 `wmgr.manageDirty()` → 概览导航后没有触发
- `overviewKeyPressed` 设完 status 就 return 了 → 无重绘

**修复：** `overviewKeyPressed` 中 `wm.status = .overview` 后加：
```zig
if (wm.river_window_manager) |wmgr| wmgr.manageDirty();
```

### 2. Super+Enter 确认选择

**现状：** `Super+Return` 已绑定到 `.spawn = .{"footclient"}`（正常模式下开终端）。

**方案：** 在 `overviewKeyPressed` 的 switch 中加 `.spawn =>` 分支，概览模式下把它解释为"选中高亮窗口并退出"：

```zig
.spawn => {
    overview.select(wm.allocator, wm);
    layout.update(wm.output_list, wm.getConfig());
    wm.status = .layout;
    return;
},
```

效果：
- 正常模式：Super+Return = 打开 footclient（不变）
- 概览模式：Super+Return = 选中高亮窗口并退出概览

> 所有其他 `.spawn` 绑定（Super+t/p/q/a/r 等）在概览下也会被解释为"选择"，这在概览模态下是合理的——你不需要在概览里开程序。

### 3. Escape 退出 overview

**现状：**
- `Super+Alt+Escape` → `.exit`（退出 compositor）
- 裸 `Escape` → 未绑定，按了无反应

**方案：** 新增 `overview_cancel: void` action，裸 `Escape` 绑定到它：

- 正常模式下 `.overview_cancel` → no-op（`keybindingPressed` 里什么都不做）
- 概览模式下 → 调 `overview.cancel()` 退出概览

这样：
- 裸 Escape：正常模式无影响，概览下退出
- Super+Alt+Escape：不变，仍退出 compositor

---

## 改动清单

| 文件 | 改动内容 |
|------|---------|
| `src/actions.zig` | `KeybindingAction` union 加 `overview_cancel: void` |
| `src/keybinding.zig` | `overviewKeyPressed` 加 `manageDirty()`、`.spawn` 分支、`.overview_cancel` 分支 |
| `src/keybinding.zig` | `keybindingPressed` 加 `.overview_cancel => {}` (no-op) |
| `config.new.zon` | 加 `.{ .key = "Escape", .modifiers = .{}, .action = .overview_cancel }` |

### 具体代码变更

**`src/actions.zig` — 加一个 variant：**
```zig
pub const KeybindingAction = union(enum) {
    // ... 现有 variants ...
    enter_overview: void,
    overview_cancel: void,   // ← 新增
    spawn: []const []const u8,
};
```

**`src/keybinding.zig` — `overviewKeyPressed` 扩展：**
```zig
fn overviewKeyPressed(
    wm: *types.WindowManager,
    xkb_binding: *river.XkbBindingV1,
) !void {
    for (wm.xkb_binding_list.items) |binding| {
        if (binding.river_xkb_binding != xkb_binding) continue;

        const state = &wm.overview_state.?;
        const total = state.origins.items.len;
        const cols = state.columns;
        const rows = (total + cols - 1) / cols;
        const cur = state.highlighted;
        const row = cur / cols;
        const col = cur % cols;
        var next = cur;

        switch (binding.action) {
            .enter_overview => {
                overview.cancel(wm.allocator, wm);
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
                return;
            },
            .exit, .overview_cancel => {                    // ← exit 和 overview_cancel 都取消
                overview.cancel(wm.allocator, wm);
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
                return;
            },
            // 方向导航（复用已有绑定）
            .focus_window_left, .focus_output_left => {
                if (col > 0) next = cur - 1;
            },
            .focus_window_right, .focus_output_right => {
                if (col + 1 < cols) next = cur + 1;
            },
            .focus_workspace_above, .focus_output_above => {
                if (row > 0) next = cur - cols;
            },
            .focus_workspace_below, .focus_output_below => {
                if (row + 1 < rows) next = cur + cols;
            },
            // Super+Enter = 选中高亮窗口并退出
            .spawn => {
                overview.select(wm.allocator, wm);
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
                return;
            },
            else => return,
        }

        if (next != cur) {
            state.highlighted = next;
            wm.status = .overview;
            if (wm.river_window_manager) |wmgr| wmgr.manageDirty();  // ← 关键修复
        }
        return;
    }
}
```

**`src/keybinding.zig` — `keybindingPressed` 加 no-op：**
在 switch 中加：
```zig
.overview_cancel => {},  // 概览外无作用
```

**`config.new.zon` — 加绑定：**
```zig
.{ .key = "Escape", .modifiers = .{}, .action = .overview_cancel },
```

---

## 按键行为总结（改动后）

| 按键 | 正常模式 | 概览模式 |
|------|---------|---------|
| Super+Left/Right/Up/Down | 窗口/output/workspace 焦点 | 网格导航 |
| Super+hjkl | 窗口焦点 | 网格导航 |
| Super+Space | 进入概览 | 取消概览（toggle） |
| Super+Return | 打开 footclient | **选中高亮窗口并退出** |
| Escape | 无作用 | **退出概览** |
| Super+Alt+Escape | 退出 compositor | 退出 compositor |
