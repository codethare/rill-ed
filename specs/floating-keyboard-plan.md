# rill-ed Floating 窗口键盘移动与缩放 — 设计方案

> 面向实现的构思文档。niri 事实依据见同目录 `niri-floating-window-keybinds.md`；rill-ed 事实依据为当前工作区源码（`src/`，base `8353d252`）逐行核验。

## 1. 结论速览

| 需求 | 方案 | 复用/新增 |
|---|---|---|
| 键盘方向移动 floating 窗口 | 新增 `move_floating_window_left/right/up/down`；`move_window_left/right` 保持纯 tiling 调换 | 新增 |
| 键盘缩放宽度 | `adjust_window_width` / `set_window_width` 改为浮动感知 | 复用（已绑 `Mod+minus/equal/BackSpace`） |
| 键盘四边缩放 | 新增 `adjust_floating_window_size`（宽高同比例、中心固定）；`set_floating_window_height` 只设高度 | 新增 |
| 浮窗默认尺寸 | `centerRectangle` 改为 16:9 等比（复用 `default_window_width` 比例） | 修改 |
| 移动步长 | 常量 50px（对齐 niri `DIRECTIONAL_MOVE_PX`） | 硬编码，不做配置 |
| 缩放语义 | `f32` 统一 = 输出可用宽/高的比例（对齐 niri 的 `+10%`/`10%` 语义，也复用现有 tiling 的 proportion 语义） | 一致 |
| 动画 | 复用现有 `start`/`finish` 机制，零新增动画代码 | 复用 |

## 2. 现状梳理（先厘清三个 "floating"）

rill-ed 有三个易混淆的 floating 概念，方案只路由到**第一个**：

| 字段 | 真实含义 | 谁设置 |
|---|---|---|
| `window.is_floating` | **逐窗口**浮动标志（真正的浮窗） | window 规则（`window.zig`）、`toggle_workspace_floating`（`keybinding.zig:299`） |
| `workspace.layout == .floating` | 整工作区浮动布局，**只被 overview 网格使用** | `overview.zig:68` |
| `workspace.is_floating` | overview 专用标志，普通运行恒为 false | `overview.zig:67,199` |

关键结论：

- **真正的浮动窗口判据是 `window.is_floating`**。现有鼠标拖拽移动/缩放（`seat.zig:135`）正是用 `if (!window.is_floating) return;` 作守卫——键盘版必须沿用同一判据，而非 `workspace.is_floating`。
- `keybinding.zig` 里 `move_window_left/right`、`adjust/set_window_width` 的 `if (workspace.is_floating) return;` 守卫是**死代码**：`workspace.is_floating` 仅在 overview 期间为 true，而 overview 期间按键在 `xkbBindingListener` 里就被 `overviewKeyPressed` 截走，根本到不了 `keybindingPressed`。改造时直接替换，无需保留。
- `window.floating` 是目标矩形，`window.current` 是动画当前矩形；`scroller.apply`（`scroller.zig:13-17`）对浮窗执行 `finish = floating; start = current`，`animation.zig` 负责插值。**所以键盘动作只要改 `window.floating`，动画、贴边、边框全部自动生效**（`keybindingPressed` 末尾已调用 `layout.update` + `wm.status = .layout`）。

## 3. 设计决策

1. **浮动判据**：一律 `window.is_floating`（对齐鼠标路径）。
2. **移动步长**：`const floating_move_step: i32 = 50;`（对齐 niri 50px，niri 亦硬编码不配置）。放 `layout/common.zig`，几何逻辑归 layout 域。
3. **缩放语义**：`f32` 复用现有 proportion 语义 = **输出可用尺寸的比例**。
   - `adjust_window_width = 0.1` → 浮窗宽 += 0.1 × 输出宽（niri `+10%` 按工作区）。
   - `set_window_width = 0.5` → 浮窗宽 = 0.5 × 输出宽（niri `10%` 绝对比例）。
   - `set_floating_window_height = 0.5` → 浮窗高 = 0.5 × 输出高。
   - `adjust_floating_window_size = 0.1` → 宽 += 0.1 × 输出宽 **且** 高 += 0.1 × 输出高（四边等比展开）。
   - 这样 tiling 与 floating 两种布局下 `f32` 含义完全一致，无需新增类型。
4. **缩放锚点**：`resizeFloatingWindow`（宽度/高度单轴）左上角固定，对齐现有鼠标缩放（`seat.zig` `.resize_window`）；`adjust_floating_window_size`（四边缩放）走 `scaleFloatingWindow`，中心固定，四边同动。
5. **边界夹取**：全部 `std.math.clamp` 到 `output.rectangle`，语义照搬 `seat.zig` 鼠标路径：
   - 移动：x ∈ `[left, right - width]`，y ∈ `[top, bottom - height]`（窗口不出屏，对齐 niri "位置夹在工作区内"）。
   - 缩放：width ∈ `[min_w, right - x]`，height ∈ `[min_h, bottom - y]`。`min_w/min_h` 取 `2 * border.width`（与 `keybinding.zig` tiling 缩放的 `2 * border.width` 下限一致）。
6. **tiling 下的新动作**：`move_floating_window_left/right/up/down`、`adjust_floating_window_size`、`set_floating_window_height` 对非 floating 窗口 no-op（`adjust/set_window_width` 保持原 proportion 逻辑不变）。
7. **fullscreen 守卫**：浮窗缩放前 `if (window.is_fullscreen) return;`（fullscreen 不受浮窗缩放影响，同现有 tiling 分支）。
8. **浮窗默认尺寸 16:9**：`centerRectangle` 的高 = 宽 × 9/16，宽 = `default_window_width` × 输出宽（复用比例，跨分辨率等比），水平/垂直居中。切换浮窗（`toggle_workspace_floating`）、window 规则命中（`window.zig`）、overview 还原均走该矩形。

## 4. 改动清单

### 4.1 `src/actions.zig` — 增 6 个 variant

`KeybindingAction` union 新增（`move_window_left/right`、`adjust/set_window_width` 签名不变）：

```zig
    move_floating_window_left: void,
    move_floating_window_right: void,
    move_floating_window_up: void,
    move_floating_window_down: void,
    adjust_floating_window_size: f32,
    set_floating_window_height: f32,
```

### 4.2 `src/layout/common.zig` — 常量 + 三个几何助手

```zig
pub const floating_move_step: i32 = 50;

/// Translate a floating window by (dx, dy) logical px, clamped to the output.
pub fn moveFloatingWindow(window: *types.Window, output: *const types.Output, dx: i32, dy: i32) void {
    const left = output.rectangle.x;
    const right = output.rectangle.x + output.rectangle.width;
    const top = output.rectangle.y;
    const bottom = output.rectangle.y + output.rectangle.height;
    window.floating.x = std.math.clamp(window.floating.x + dx, left, right - window.floating.width);
    window.floating.y = std.math.clamp(window.floating.y + dy, top, bottom - window.floating.height);
}

/// Resize a floating window by (dw, dh) logical px, top-left anchored, clamped.
pub fn resizeFloatingWindow(window: *types.Window, output: *const types.Output, dw: i32, dh: i32, min_size: i32) void {
    const right = output.rectangle.x + output.rectangle.width;
    const bottom = output.rectangle.y + output.rectangle.height;
    window.floating.width = std.math.clamp(window.floating.width + dw, min_size, right - window.floating.x);
    window.floating.height = std.math.clamp(window.floating.height + dh, min_size, bottom - window.floating.y);
}

/// Expand/shrink a floating window on all four sides, center fixed, clamped.
pub fn scaleFloatingWindow(window: *types.Window, output: *const types.Output, dw: i32, dh: i32, min_size: i32) void {
    const left = output.rectangle.x;
    const right = output.rectangle.x + output.rectangle.width;
    const top = output.rectangle.y;
    const bottom = output.rectangle.y + output.rectangle.height;

    const new_width = std.math.clamp(window.floating.width + dw, min_size, right - left);
    const new_height = std.math.clamp(window.floating.height + dh, min_size, bottom - top);

    const cx = window.floating.x + @divTrunc(window.floating.width, 2);
    const cy = window.floating.y + @divTrunc(window.floating.height, 2);

    window.floating.width = new_width;
    window.floating.height = new_height;
    window.floating.x = std.math.clamp(cx - @divTrunc(new_width, 2), left, right - new_width);
    window.floating.y = std.math.clamp(cy - @divTrunc(new_height, 2), top, bottom - new_height);
}
```

`centerRectangle` 改为 16:9 等比（见 §3 决策 8），`initialRectangle` 不变（tiling 用）。

### 4.3 `src/keybinding.zig` — 路由 + 新分支

顶部加 `const common = @import("layout/common.zig");`。

`move_window_left` / `move_window_right`（**纯 tiling 左右调换**，不再感知 floating；顺手去掉死代码 `if (workspace.is_floating) return;`）：

```zig
.move_window_left => {
    const window_idx = workspace.focused_window_idx orelse return;
    if (window_idx >= workspace.window_list.items.len) return;
    if (window_idx == 0) return;
    std.mem.swap(
        types.Window,
        &workspace.window_list.items[window_idx],
        &workspace.window_list.items[window_idx - 1],
    );
    workspace.focused_window_idx = window_idx - 1;
},
```

新增 `move_floating_window_left` / `move_floating_window_right` / `move_floating_window_up` / `move_floating_window_down`（全部 50px 步长，仅 floating）：

```zig
.move_floating_window_left => {
    const window = ws.focusedWindow() orelse return;
    if (!window.is_floating) return;
    common.moveFloatingWindow(window, output, -common.floating_move_step, 0);
},
.move_floating_window_right => {
    const window = ws.focusedWindow() orelse return;
    if (!window.is_floating) return;
    common.moveFloatingWindow(window, output, common.floating_move_step, 0);
},
.move_floating_window_up => {
    const window = ws.focusedWindow() orelse return;
    if (!window.is_floating) return;
    common.moveFloatingWindow(window, output, 0, -common.floating_move_step);
},
.move_floating_window_down => {
    const window = ws.focusedWindow() orelse return;
    if (!window.is_floating) return;
    common.moveFloatingWindow(window, output, 0, common.floating_move_step);
},
```

`adjust_window_width` / `set_window_width`（浮动分支，比例→像素）：

```zig
.adjust_window_width => |increment| {
    const window = ws.focusedWindow() orelse return;
    if (window.is_floating) {
        if (window.is_fullscreen) return;
        const dw: i32 = @intFromFloat(@as(f32, @floatFromInt(output.non_exclusive.width)) * increment);
        common.resizeFloatingWindow(window, output, dw, 0, 2 * wm.getConfig().border.width);
    } else {
        // 现有 tiling proportion 逻辑原样保留
    }
},
.set_window_width => |proportion| {
    const window = ws.focusedWindow() orelse return;
    if (window.is_floating) {
        if (window.is_fullscreen) return;
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(output.non_exclusive.width)) * proportion);
        window.floating.width = std.math.clamp(w, 2 * wm.getConfig().border.width, output.rectangle.x + output.rectangle.width - window.floating.x);
    } else {
        window.proportion = proportion;
    }
},
```

新增 `adjust_floating_window_size`（**四边缩放**：宽高同比例、中心固定）与 `set_floating_window_height`（只设高度）：

```zig
.adjust_floating_window_size => |increment| {
    const window = ws.focusedWindow() orelse return;
    if (!window.is_floating) return;
    if (window.is_fullscreen) return;
    const base_width: f32 = @floatFromInt(output.non_exclusive.width);
    const base_height: f32 = @floatFromInt(output.non_exclusive.height);
    const dw: i32 = @trunc(base_width * increment);
    const dh: i32 = @trunc(base_height * increment);
    const min_size: i32 = 2 * @as(i32, wm.getConfig().border.width);
    common.scaleFloatingWindow(window, output, dw, dh, min_size);
},
.set_floating_window_height => |proportion| {
    const window = ws.focusedWindow() orelse return;
    if (!window.is_floating) return;
    if (window.is_fullscreen) return;
    const h: i32 = @intFromFloat(@as(f32, @floatFromInt(output.non_exclusive.height)) * proportion);
    window.floating.height = std.math.clamp(h, 2 * wm.getConfig().border.width, output.rectangle.y + output.rectangle.height - window.floating.y);
},
```

所有分支都落到 `keybindingPressed` 末尾既有的 `layout.update` + `wm.status = .layout`，动画与贴边自动完成。

### 4.4 默认键位（`keybinding.zig` `default_keybindings` + `config.new.zon`）

对齐 niri 的 vi 风格，全部避开现有绑定（`Mod+Ctrl` 当前未占用）：

| 键 | action | 说明 |
|---|---|---|
| `Mod+Ctrl+H` | `move_floating_window_left` | 浮动左移 50px |
| `Mod+Ctrl+L` | `move_floating_window_right` | 浮动右移 50px |
| `Mod+Ctrl+J` | `move_floating_window_down` | 浮动下移 50px |
| `Mod+Ctrl+K` | `move_floating_window_up` | 浮动上移 50px |
| `Mod+Ctrl+equal` | `adjust_floating_window_size = 0.1` | 浮动四边放大 10% |
| `Mod+Ctrl+minus` | `adjust_floating_window_size = -0.1` | 浮动四边缩小 10% |
| `Mod+Ctrl+BackSpace` | `set_floating_window_height = 0.5` | 浮动高度 = 50% 输出高 |

宽度缩放复用现有 `Mod+minus/equal`（`adjust_window_width ±0.1`）与 `Mod+BackSpace`（`set_window_width 0.5`）——这些键在浮窗焦点下自动变成浮窗缩放，tiling 下行为不变。

tiling 左右调换仍由 `move_window_left/right` 承担，绑 `Mod+Shift+Left/Right`（config.new.zon 为 `Mod+Shift+H/L`），与浮窗移动键位互不干扰。

## 5. 边界与坑

- **按住连发（key repeat）的动画重置**：river xkb 重复触发 `.pressed`，每次 `layout.update` 都把 `start` 重置为中途的 `current`（`scroller.zig` 对浮窗无条件 `start = current`），连续移动会轻微"追目标"而非严格累加步长。与 niri 行为近似，视觉上平滑可接受，不作为本次修复项。若介意，方案是连发时同步 `current = floating`（跳步不动画）——单行改动，留待确认。
- **workspace 偏移**：`window.floating.y` 是焦点工作区屏幕坐标，焦点窗口必在焦点工作区，故 `y_offset == 0`，直接用 `output.rectangle` 夹取正确。无需处理非焦点工作区。
- **overview 交互**：overview 期间按键被 `overviewKeyPressed` 截走，新动作不会在网格里误触发；overview 导航复用 `focus_window_*` 系列（`move_window_left/right` 已无浮窗分支，导航不受影响）。
- **`toggle_workspace_floating` 命名陷阱**：它实际切换的是 `window.is_floating`（逐窗口），本方案按这个语义路由，不引入新概念。

## 6. 验证计划

- **单测（最小可运行检查）**：在 `src/layout/common.zig` 加 `test`，构造 `Window` + `Output`，断言：
  1. `moveFloatingWindow` 移动 50px 后 `floating.x/y` 正确，且越界被 clamp 到 `right - width` / `bottom - height`。
  2. `resizeFloatingWindow` 增大/缩小后不越过输出边界、不小于 `min_size`。
  3. `scaleFloatingWindow` 四边缩放后中心不变、不越过输出边界、不小于 `min_size`。
  4. `centerRectangle` 宽高 16:9、水平/垂直居中。
- **构建**：`zig build` + `zig build test`（13 用例全绿）。
- **手工验收**：`Mod+V` 转浮窗 → 默认 16:9 等比居中 → `Mod+Ctrl+HJKL` 移动、`Mod+minus/equal` 缩放宽度、`Mod+Ctrl+minus/equal` 四边缩放 → 确认窗口不漂出屏幕、动画平滑、tiling 窗口的 `Mod+Shift+Left/Right` 换位行为不变。
