# rill-ed 性能热路径分析

项目：rill-ed（Zig 0.16，river Wayland WM）
范围：`src/main.zig`、`src/layout.zig`、`src/layout/scroller.zig`、`src/layout/common.zig`、`src/animation.zig`、`src/types.zig`、`src/config.zig`、`src/keybinding.zig`、`src/seat.zig`

## 执行摘要

- 无每帧堆分配；`animation.apply()` 和 `layout.update()` 均为纯迭代。
- 真正的性能成本在 Wayland 协议调用（`proposeDimensions`、`setPosition`、`setClipBox`、`setBorders`、`show`/`hide`）而非 CPU 计算。
- 热路径复杂度均为 O(输出数 × 10 workspace × 窗口数)，在典型桌面场景（1–3 输出、每 workspace 少量窗口）下完全可忽略。
- 唯一值得优先处理的明确收益项：`getConfig()` 的按值返回导致 Config 结构体被反复浅拷贝，建议改为指针传递。
- 其余潜在优化（预分配 ArrayList、减少 `manageDirty` 调用）收益有限或需以正确性为代价，当前不推荐。

## 逐项瓶颈

### 1. `getConfig()` 按值返回 Config — WARM

- **位置**：`src/types.zig:96`（`pub fn getConfig(self: *WindowManager) Config`）
- **模式**：每次调用返回整个 `Config` 结构体的副本。Config 包含多个 slice（`keybindings`、`pointer_bindings`、`spawn_at_startup`）以及嵌套 struct，虽然 slice 是浅拷贝（指针+长度），但整个结构体仍会被逐字段复制。
- **被调频率**：
  - 每帧动画：`animation.apply()` 调用一次（`src/animation.zig:13`）。
  - 每次布局更新：`layout.update()` 调用一次（`src/layout.zig:12`）。
  - 几乎每个 keybinding action：`keybinding.zig` 中多次调用（如 `adjust_window_width`、`reload_config`、overview 等）。
  - 每次 pointer action：`seat.pointerAction()` 调用一次（`src/seat.zig:191`）。
  - 每次 output 维度/非独占区域变化、窗口添加/关闭等。
- **估算**：每 manage/frame 周期 3–10 次拷贝，Config 大小约 80–120 字节。现代 CPU 上成本极低，但属于无收益开销。
- **改进建议**：
  - 将 `getConfig()` 改为返回 `*const Config`，或直接在需要处访问 `wm.config.*`。
  - 需要修改所有调用点（约 20+ 处），但均为机械替换，风险低。
  - **注意**：`Config` 包含 slice，按值返回不会深拷贝 slice 内容，因此当前没有功能正确性问题；优化仅为消除冗余拷贝。

### 2. `animation.apply()` 每帧迭代 — HOT

- **位置**：`src/animation.zig:7`
- **模式**：每帧遍历所有 output、workspace（10 个）、window，计算插值并调用 `placeWindow()`。
- **被调频率**：动画持续期间每帧一次（由 `main.zig:76` 的 `manageDirty()` 驱动）。
- **关键观察**：
  - 无堆分配，无 `ArrayList` 扩容。
  - 主要成本在 `placeWindow()` 内部的 Wayland 协议请求：`proposeDimensions`、`setPosition`、`setClipBox`、`show`/`hide`。
  - 每个窗口每帧产生 4 次协议请求；对于 10 个窗口 + 60fps，约 2400 请求/秒，协议序列化是瓶颈而非 CPU。
- **改进建议**：
  - 当前已足够高效；不要引入复杂脏区域或分层渲染。
  - 可考虑的一个小优化：对未改变（`start == finish` 或已完成）的窗口跳过 `proposeDimensions`/`setPosition`，但 river 协议本身可能已经做了去重，需实测验证。
  - **不推荐**：缓存几何计算（矩形裁剪等），因为当前数学非常简单，缓存反而增加内存和分支。

### 3. `layout.update()` 调用频率 — WARM/HOT

- **位置**：`src/layout.zig:10`
- **模式**：遍历所有 output 和 workspace，根据布局类型（scroller/floating）计算 `window.finish`。
- **被调频率**：
  - 每次窗口添加/关闭/焦点变化/输出尺寸变化/非独占区域变化：都会调用。
  - 在 `keybindingPressed()` 中几乎每个 action 后调用（`src/keybinding.zig:433`）。
  - 在 `seatListener.window_interaction` 中调用。
  - 在 `overview.enter()` 中调用。
- **关键观察**：
  - 调用次数多，但每次计算量小（scroller 为 O(N)）。
  - 对只改变焦点而不改变窗口集合的 action，仍然重新计算整个 focused output 的所有 workspace；这是必要行为，因为 scroller 需要重新布局。
- **改进建议**：
  - 无需改动。Workspace 数量固定为 10，窗口数少，O(N) 可忽略。
  - 如果未来支持大量窗口，可考虑只标记 dirty 的 workspace，但当前 YAGNI。

### 4. `manageDirty()` 调用频率 — HOT

- **位置**：`src/main.zig:76`
- **模式**：主循环在 `status == .animation` 时每轮 `display.dispatch()` 都调用 `manageDirty()`，触发一次完整 manage 周期。
- **被调频率**：动画期间每 display 事件循环迭代一次，实际帧率由 Wayland 事件循环和显示器刷新率共同决定。
- **关键观察**：
  - 这是动画推进所必需：`animation.apply()` 只在 `manage_start` 时执行，因此需要持续请求 manage 序列。
  - 没有多余的睡眠或定时器；事件驱动模型是合理的。
- **改进建议**：
  - 不要减少调用。若改为基于定时器的睡眠，反而增加延迟和复杂度。
  - 如果观察到高 CPU，问题更可能在 Wayland 协议调用量，而非 `manageDirty()` 本身。

### 5. `keybinding.setupKeybindings()` 重建所有 binding — WARM

- **位置**：`src/keybinding.zig:13`
- **模式**：每次调用先销毁所有现有 `river_xkb_binding`，清空列表，再重新创建并 append。
- **被调频率**：
  - 启动时一次（`.seat` 事件）。
  - 每次 `reload_config` 一次。
- **关键观察**：
  - 默认 keybinding 数量约 40 个，创建/销毁的是 Wayland proxy 对象，成本在于协议往返而非本地 CPU。
  - `xkb_binding_list` 使用 `clearRetainingCapacity()`，不会释放底层容量，因此后续 reload 时 append 不会重新分配内存。
- **改进建议**：
  - 当前无需优化。reload 频率低，且销毁重建是正确做法（避免旧 binding 与新配置不一致）。
  - 如果要优化，可考虑 diff keybinding 配置只增删改，但代码复杂度远高于收益。

### 6. `seat.setupPointerBindings()` — COLD

- **位置**：`src/seat.zig:89`
- **模式**：与 keybinding 类似，但默认只有 2 个 pointer binding。
- **被调频率**：启动和 `reload_config`。
- **改进建议**：无需优化。

### 7. Scroller 布局算法复杂度 — HOT

- **位置**：`src/layout/scroller.zig:8`
- **模式**：
  - 先处理 floating 窗口（O(N)）。
  - 定位 focused 窗口（O(1)）。
  - 向右遍历 unfocused 窗口（O(N)）。
  - 向左遍历 unfocused 窗口（O(N)）。
  - `snapToEdge()` 再扫描首尾（O(N)）。
- **总复杂度**：O(N)，N 为一个 workspace 中的窗口数。
- **关键观察**：
  - 当 focused 窗口为 floating 时，使用 anchor 循环（`while (i != anchor_idx)`）仍是 O(N)。
  - 没有嵌套循环，没有每窗口分配。
- **改进建议**：无需改动。O(N) 已是最优，且 N 通常很小。

### 8. ArrayList append 在关键路径 — WARM

- **位置**：
  - `src/layout.zig:23`：`layout.pending_windows.append()`（窗口事件时）。
  - `src/window.zig:72`：`workspace.window_list.insert()`（添加窗口）。
  - `src/keybinding.zig:34`、`src/seat.zig:103`：binding list append。
- **模式**：在可能扩容的情况下会触发堆分配。
- **被调频率**：窗口生命周期事件、配置重载，非每帧。
- **改进建议**：
  - `pending_windows` 通常只含少量元素；默认容量策略足够。
  - `workspace.window_list` 可考虑在已知典型窗口数时预分配（如 `ensureTotalCapacity(4)`），但收益微小且需要在 output add 时初始化。
  - **不推荐**：当前不值得引入预分配逻辑。

### 9. `Color.toRiverColor()` 重复计算 — COLD/WARM

- **位置**：`src/types.zig:158`
- **模式**：每次 `layout.apply()` 为 focused/unfocused border 各调用一次，将 8-bit RGBA 转换为 32-bit premultiplied。
- **被调频率**：每次 `layout.apply()`（即每次 manage cycle）。
- **关键观察**：
  - 每 manage cycle 调用 2 次；border color 在运行时不变化（除非 reload config）。
  - 计算非常轻量（几次浮点乘）。
- **改进建议**：
  - 可在 `Config` 中缓存转换后的 river color，但收益可忽略。
  - 如果要消除 `getConfig()` 拷贝，顺带缓存 river color 也可以，但不是必要项。

### 10. `placeWindow()` 中的裁剪盒计算 — HOT

- **位置**：`src/animation.zig:111`
- **模式**：每帧每个窗口计算与 output 矩形的交集，生成 clip box。
- **被调频率**：动画每帧每个可见/部分可见窗口。
- **关键观察**：
  - 纯整数比较和简单算术，无循环、无分配。
  - 紧随其后的 `setClipBox` 协议调用成本远高于计算。
- **改进建议**：无需改动。

## 优先级排序

1. **P1（建议做）**：将 `getConfig()` 改为返回 `*const Config`（或等效减少拷贝）。
   - 改动小、风险低、调用点多但机械。
   - 明确消除每次 manage/frame/action 中 Config 结构体的浅拷贝。

2. **P2（可选/需基准）**：评估是否对未移动窗口跳过 `proposeDimensions`/`setPosition`。
   - 只有实测显示协议调用是瓶颈时才做。
   - 当前 river 可能已经做了足够的去重，贸然优化可能引入显示不同步风险。

3. **P3（不推荐当前做）**：ArrayList 预分配、Color 缓存、布局脏标记等。
   - 收益在当前窗口规模下不可测，增加代码复杂度。

## 明确不推荐的方向

- **ArenaAllocator**：无大量短生命周期分配，引入 arena 反而增加作用域管理负担。
- **f32/f64 精度调整、循环展开、@inline**：当前瓶颈不在 CPU 计算。
- **每帧减少 `manageDirty()` 调用**：会打断动画推进，得不偿失。
- **diff keybinding 配置**：reload 频率低，diff 逻辑复杂且容易出错。
