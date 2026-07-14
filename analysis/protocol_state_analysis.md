# Wayland 协议安全与状态机分析报告

## 范围
对 rill-ed（Zig 0.16，river 窗口管理器客户端）的 Wayland 协议事件处理、状态机转换、TTY 切换、多输出场景进行安全性分析。

已读文件：
- `src/main.zig`, `src/window.zig`, `src/output.zig`, `src/seat.zig`, `src/layout.zig`, `src/types.zig`, `src/keybinding.zig`, `src/animation.zig`, `src/config.zig`, `src/overview.zig`
- `protocol/river-window-management-v1.xml`
- `focus_analysis.md`, `keybinding_analysis.md`

验证命令：`zig build test`（通过）

---

## 状态机总览

```
WindowManager.status = union(enum) {
    none,            // 空闲，等待 manage_start
    layout,          // 需要重新布局
    animation(i64),  // 动画中，记录开始时间
    pointer_action,  // 指针交互（移动/缩放浮动窗口）
    overview,        // 概览模式
    setup_bindings,  // 需要重新设置键绑定
    exit,            // 退出会话
}
```

正常 manage 周期：
```
manage_start → .layout → layout.apply() → .animation → animation.apply() → .none → opEnd
```

---

## 逐项发现

### 1. TTY 切回单屏场景仍存在重复窗口（focus_analysis.md Bug 3 未完全修复）

`src/main.zig:133` — `manage()` 在 `focused_output_idx == null` 时直接 `return`，不调用 `layout.apply()`。

单屏 TTY 切出流程：
1. `output.removed` → `outputListener` 把 `focused_output_idx` 设为 `null`
2. `manage_start` → `manage()` 早退，`layout.apply()` 不执行
3. 旧 output 仍留在 `output_list` 中（`is_removed=true`），其 `workspace_list` 未被清理或 detach

TTY 切回：
1. 新 output 被加入，`focused_output_idx = 1`
2. 下一个 `manage_start` → `layout.apply()`
3. `apply()` 发现 idx 0 是 removed output，idx 1 是新 output，触发 migration
4. 旧窗口对象（引用已失效的 `river_window_v1`）被复制到新 output 的 workspace
5. 随后 river 重新发送新窗口的 `.dimensions` 事件，`windowListener` 把新窗口对象加入同一个 workspace

结果：workspace 中同时存在 **旧代理（stale）** 和 **新代理（fresh）** 的窗口条目，导致重复布局、潜在协议错误（对旧代理调用 `setBorders`/`proposeDimensions`）。

**文件:行号**：`src/main.zig:133`, `src/layout.zig:210-240`  
**严重度**：MAJOR  
**根因**：单屏全移除时 `manage()` 早退，旧 output 未被清理；切回时 `apply()` 把旧输出当作"普通 removed output"迁移而不是丢弃。  
**修复方向**：
- 方案 A：当所有 output 都被移除时，在 `outputListener` 中直接清理 removed outputs（或设置 `detached_workspaces`），避免切回时迁移。
- 方案 B：在 `layout.apply()` 中区分"有目标可迁移"与"这是 TTY 切回、river 会重发窗口"，对后者走 free-memory 分支。
- 最小改动：在单屏早退路径里调用一次轻量清理，把旧 output 标记为 detached 或清空其 `workspace_list`。

---

### 2. `pending_windows` 在窗口关闭后残留 stale 条目

`src/window.zig:33-46` — `.closed` 事件把窗口从 workspace 移除并 `river_window.destroy()`，但 **没有从 `layout.pending_windows` 中移除**。

如果一个窗口在收到 `.dimensions` 之前就被关闭：
1. `.window` 事件把它加入 `pending_windows`
2. `.closed` 事件把它从 workspace 移除（此时还不在 workspace 中，所以实际无操作）并 destroy
3. 下一个 `manage_start` → `layout.apply()` 遍历 `pending_windows`，对已 destroy 的 `river_window_v1` 调用 `useSsd()` / `setTiled()` / `proposeDimensions(0,0)`

协议规定：对象收到 `closed` 后，除 `destroy()` 外任何请求都是协议错误（`river_window_v1.closed` description）。

**文件:行号**：`src/window.zig:33-46`, `src/layout.zig:24-29`  
**严重度**：MAJOR（协议错误，可能被 compositor 断开）  
**根因**：`windowListener` 的 `.closed` 处理不清理 `pending_windows`。  
**修复方向**：在 `.closed` 分支中，同时扫描 `layout.pending_windows` 并 `swapRemove` 对应条目；或统一在 `layout.apply()` 前过滤掉已 closed 的 pending 窗口。

---

### 3. `river_window_manager_v1.unavailable` 事件被静默忽略

`src/main.zig:121` — `windowManagerListener` 的 `else => {}` 忽略了 `session_locked`、`session_unlocked` 和 `unavailable`。

`unavailable` 表示另一个 WM 已抢占 river 的窗口管理权限：
> "If sent, this event is guaranteed to be first and only event sent by the server. The server will send no further events on this object. The client should destroy this object and all objects created through this interface."

当前代码忽略它后，主循环继续 `display.dispatch()`，但 river 不会再发送任何事件，程序会空转；更糟的是，如果之后收到其他对象事件，可能操作无效/已销毁的对象。

**文件:行号**：`src/main.zig:121`  
**严重度**：MAJOR（功能失效 + 潜在未定义行为）  
**根因**：`else => {}` 吞掉 critical 事件。  
**修复方向**：显式处理 `.unavailable`：打印错误并退出主循环（或优雅清理）。`session_locked`/`session_unlocked` 可继续忽略但建议显式注释。

---

### 4. `reload_config` 存在状态竞争

`src/keybinding.zig:335-344` — `.reload_config` 动作：
1. 调用 `config.reload()` 替换 `wm.config`
2. 设置 `wm.status = .setup_bindings`
3. return

问题：`wm.status = .setup_bindings` 是一个"期望下一个 manage_start 去设置绑定"的标记。如果在 `.pressed` 事件与 `manage_start` 之间，其他事件监听器（如 `windowListener.dimensions`、`outputListener.dimensions`）把 `wm.status` 改成 `.layout`，则下一个 `manage()` 会走 `.layout` 分支而不是 `.setup_bindings`，导致：
- 新配置已加载但键绑定仍是旧的
- 光标主题可能已更新但绑定未重建

虽然 Wayland 事件按顺序处理，但 `.pressed` 本身只是"后面会跟 manage_start"，而 `.window`/`.output` 等事件同样会跟 manage_start，它们可以穿插在 binding `.pressed` 与 manage_start 之间。

**文件:行号**：`src/keybinding.zig:335-344`, `src/main.zig:104-117`  
**严重度**：MAJOR（配置 reload 后键绑定不生效，需用户再次按 reload）  
**根因**：用 `status` 作为"待处理事务"队列，且 `.layout` 等事件会覆盖它。  
**修复方向**：
- 方案 A：`.reload_config` 直接调用 `keybinding.setupKeybindings()` 和 `seat.setupPointerBindings()`（在事件回调里同步完成），不依赖 manage 周期。
- 方案 B：引入独立标志位 `needs_setup_bindings`，`manage()` 在 `.layout`/`animation` 之后仍检查并执行绑定重建。
- 方案 C：`.reload_config` 调用 `manageDirty()` 并把 status 保留为 `.setup_bindings`，但需要防止中间事件覆盖——可用独立标志更安全。

---

### 5. 动画主循环中每轮都调用 `manageDirty()`

`src/main.zig:81-83`：
```zig
while (true) {
    _ = display.dispatch();
    if (wm.status == .animation) window_manager.manageDirty();
}
```

`manage_dirty` 文档：
> "If this request is made during an ongoing manage sequence, a new manage sequence will be started as soon as the current one is completed."

动画期间不在 manage sequence 内，因此每轮 dispatch 都在请求新的 manage sequence。即使 river 会合并或忽略冗余请求，这也属于不必要的协议流量。更关键的是，这会把"渲染状态更新"变成"完整 manage + render 周期"，与协议设计意图（渲染状态应在 render sequence 中完成）不完全一致。

**文件:行号**：`src/main.zig:81-83`  
**严重度**：MINOR（性能 + 协议语义偏差）  
**根因**：动画没有使用 render sequence 驱动，而是用 manage sequence 反复触发。  
**修复方向**：
- 仅在动画状态进入时调用一次 `manageDirty()`，而不是每轮 dispatch。
- 或改用 render sequence 机制：`render_start` 到来时更新动画帧并 `renderFinish()`，避免每个动画帧都走 manage。

---

### 6. `session_locked` / `session_unlocked` 被忽略

`src/main.zig:121` `else => {}` 忽略了这两个事件。

协议说明：
> "This event will be followed by a manage_start event after all other new state has been sent by the server."

由于随后会跟 manage_start，所以功能上不会崩溃，但 rill 没有利用 locked 状态来限制锁屏时的键绑定。如果 river 在锁屏时仍把输入路由给 rill，某些绑定（如 spawn terminal、exit session）可能被意外触发。

**文件:行号**：`src/main.zig:121`  
**严重度**：MINOR（安全/功能缺口）  
**根因**：事件被吞。  
**修复方向**：显式处理并记录 locked 状态；在锁屏时拦截非安全绑定（如 `exit`、`spawn`）。

---

### 7. `focused_output_idx` 与多输出全移除

当前 `outputListener` 已修复 keybinding_analysis.md 指出的问题：计算 active_count 而非依赖 `items.len == 1`，并在 focus output 被移除时切换到第一个存活 output。

但仍有一个边界：如果所有 output 同时被移除（如多 GPU 热插拔），`active_count == 0` 会把 `focused_output_idx` 设为 `null`。这与 `manage()` 的早退逻辑组合，会导致旧 outputs 不被清理，切回时再次触发迁移/重复窗口问题。

**文件:行号**：`src/output.zig:56-78`, `src/main.zig:133`  
**严重度**：MINOR（极端硬件场景）  
**根因**：全移除时 manage 早退，清理被延迟。  
**修复方向**：与发现 #1 同根因，统一处理全移除场景的清理。

---

### 8. `seatListener` 忽略 `.removed` 事件

`src/seat.zig:90` `else => {}` 忽略 `river_seat_v1.removed`。

TTY 切换不会触发 seat removed（seat 持久化），但如果未来支持 seat 热插拔或 river 行为变化，`wm.river_seat` 将变成悬空指针。

**文件:行号**：`src/seat.zig:90`  
**严重度**：MINOR（防御性缺口）  
**根因**：事件被吞。  
**修复方向**：显式处理 `.removed`：清理 `river_seat`，必要时进入安全状态。

---

### 9. `Status` 转换路径覆盖情况

`manage()` 处理所有 7 个 status 变体，覆盖完整。

但存在以下可疑转换：
- `.setup_bindings` → 成功后进入 `.layout` 并立即 `manageDirty()`。如果绑定设置失败（bind_ok=false）则直接 return，**没有恢复 status**。失败后 status 停留在 `.setup_bindings`，下一个 `manage_start` 会重试，这本身合理，但如果在失败期间其他事件改写了 status 则行为不确定。
- `.overview` → 设置 status 为 `.animation` 的时间戳，但没有调用 `manageDirty()`。`overview.enter()` 已经调用过，这里依赖后续事件触发 manage_start，可接受。
- `.pointer_action` → 每次 manage_start 都调用 `opStartPointer()`。协议说该请求在已有操作进行时被忽略，所以安全，但属于冗余调用。

**文件:行号**：`src/main.zig:140-190`  
**严重度**：INFO / MINOR  
**根因**：状态转换健壮性可提升。  
**修复方向**：失败时显式恢复 status 或记录日志；`.pointer_action` 分支可考虑在首次进入时调用 `opStartPointer()`。

---

### 10. `layout.apply()` 中 `proposeDimensions(0,0)` 与 `setTiled` 对 pending 窗口的调用

`src/layout.zig:24-29`：
```zig
for (pending_windows.items) |window| {
    if (config.no_csd) window.useSsd();
    window.setTiled(common.edges);
    window.proposeDimensions(0, 0);
}
```

这些请求是窗口管理状态，只能在 manage sequence 中调用。`apply()` 确实在 `manage_start` 时调用，所以符合协议时序。

但未调用 `set_capabilities()`，协议建议 WM 应对所有新窗口设置 capabilities：
> "The window manager client should use this request to set capabilities for all new windows."

当前 rill 忽略所有窗口请求（maximize/fullscreen/minimize/show_window_menu 等），但不告知窗口不支持这些能力，窗口可能仍然显示最大化/最小化按钮。

**文件:行号**：`src/layout.zig:24-29`  
**严重度**：MINOR（功能/协议建议）  
**根因**：未实现 `set_capabilities`。  
**修复方向**：在 pending_windows 初始化时调用 `window.set_capabilities(.{})` 或显式关闭不需要的能力。

---

## 优先级建议

| 优先级 | 问题 | 理由 |
|--------|------|------|
| P0 | #3 `unavailable` 被忽略 | 另一个 WM 抢占时程序行为未定义，应优雅退出 |
| P0 | #2 `pending_windows` stale 条目 | 对 closed 窗口发请求 = 协议错误，可能被断开 |
| P1 | #1 TTY 切回重复窗口 | 单屏 TTY 切换是项目重点功能，会导致窗口重复/代理失效 |
| P1 | #4 `reload_config` 状态竞争 | 配置 reload 是用户高频操作，绑定不生效体验差 |
| P2 | #5 动画循环 `manageDirty` spam | 性能优化，减少不必要 manage cycle |
| P2 | #6 `session_locked` 处理 | 锁屏安全 |
| P3 | #7 多输出全移除 | 极端硬件场景 |
| P3 | #8 `seat.removed` | 防御性 |
| P3 | #10 `set_capabilities` | 协议建议 |

---

## 验证

- `zig build test`：通过
- 代码静态走查：确认 `focus_analysis.md` Bug 1/2 已修复，Bug 3/4 仍相关
