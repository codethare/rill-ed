# rill-ed 优化报告 — 四视角综合评审

**项目**: rill-ed — river compositor 的 Wayland 窗口管理器  
**代码规模**: 15 个源文件, 3664 行 Zig  
**评审视角**: 代码质量 · 性能 · 架构 · 协议合规  

---

## 1. 执行摘要

| 指标 | 值 |
|------|-----|
| **整体评级** | **B-** |
| CRITICAL 问题 | 6 个 |
| HIGH 问题 | 8 个 |
| MEDIUM 问题 | 10 个 |
| LOW 问题 | 9 个 |

**结论**: rill-ed 是一个功能完整、协议集成正确的 Wayland 窗口管理器。锁协议、输出生命周期、动画系统设计合理。但在内存安全（overview 索引失效、OOM 路径泄漏）、协议合规（manage sequence 外的状态修改）、信号处理（无 SIGPIPE）和性能热点（每次事件全量扫描）方面存在系统性缺陷。项目结构清晰但 `layout.zig`（486行）承担了过多职责。

**关键健康指标**:
- ✅ 协议集成正确: manage sequence、session lock/unlock、output lifecycle
- ✅ 内存管理意识强: 大部分路径有 defer/errdefer
- ⚠️ 错误处理不一致: 部分 panic、部分静默丢弃、部分传播
- ❌ 无 SIGPIPE 处理: compositor 崩溃时进程被直接杀死
- ❌ Overview 索引在多输出场景下不可靠

---

## 2. 关键问题 (CRITICAL)

### C-1. SIGPIPE 未处理 — compositor 崩溃时进程被直接杀死
**文件**: `src/main.zig:28-37`  
**影响**: 用户体验 + 数据丢失

信号处理仅设置 `SIGCHLD`，未忽略 `SIGPIPE`。当 river compositor 崩溃时，任何对 Wayland socket 的写操作都会触发 `SIGPIPE`，导致 rill-ed 被内核直接终止。`defer display.disconnect()` 和 `defer wm.deinit()` 不会执行，pending windows 的 proxy 泄漏，输出状态不一致。

```zig
// 当前: 仅处理 SIGCHLD
const sa = std.posix.Sigaction{ ... };
std.posix.sigaction(std.posix.SIG.CHLD, &sa, null);
// 缺失: SIGPIPE → SIG_IGN
```

**修复**: 添加 `SIGPIPE` → `SIG_IGN`，并在 `wl_display_flush()` 返回 `EPIPE` 时主动退出循环。

---

### C-2. Overview `origins` 索引在多输出场景下失效
**文件**: `src/overview.zig:68-74, 117-130`  
**影响**: 窗口丢失 / index-out-of-bounds panic

`overview.enter()` 中，对聚焦输出的 workspace 0 记录 `win_idx`（来自 for-each 循环），这些窗口不被移动，索引正确。但 `restoreWindows()` 使用 `origin.output_idx` 直接索引 `wm.output_list.items`，**未验证该输出是否仍然存在**。如果用户在 overview 期间断开显示器（DPMS off/on），`origin.output_idx` 指向已移除的输出，导致 OOB panic：

```zig
// overview.zig:117
const dst_output = &wm.output_list.items[origin.output_idx]; // panic if output removed
```

此外，`select()` 中使用 `origin.window_idx` 索引 `ws.window_list.items`，但 `restoreWindows()` 以 `insert_at = 0` 反序插入，导致 `window_idx` 与实际位置不匹配。

**修复**: `restoreWindows()` 中添加 bounds 检查；使用窗口指针或重新计算索引替代硬编码位置。

---

### C-3. `focused_output_idx` 在 manage sequence 外被修改
**文件**: `src/output.zig:104-118`  
**影响**: 协议违规 + 潜在 use-after-free

`outputListener.removed` 在输出移除时直接修改 `wm.focused_output_idx`、`wm.needs_pointer_warp`、`wm.previous_workspace`。根据 river-window-management-v1 协议：

> *"Window management state may only be modified by the window manager as part of a manage sequence."*

虽然代码中有注释承认这一问题（`output.zig:85-92`），但仍然执行了修改。如果在输出移除和下一个 `manageDirty()` 调用之间有任何事件到达（如 `.window` 事件、seat 事件），`currentFocus()` 可能解引用已移除输出的数据。

**修复**: 将所有 `focused_output_idx`/`needs_pointer_warp`/`previous_workspace` 的修改从 `outputListener.removed` 移入 `layout.apply()`。

---

### C-4. `layout.update()` 在 manage sequence 外被调用
**文件**: `src/output.zig:130-131` (`layerShellOutputListener`)  
**影响**: 协议违规

`layerShellOutputListener` 直接调用 `layout.update()`，该函数修改窗口的 `start`/`finish` 矩形并通过 `river_window.proposeDimensions()` 发送请求。这些都是 window management state 修改，应在 manage sequence 内执行。

**修复**: 移除直接调用，改为设置 `wm.status = .layout` + `manageDirty()`。

---

### C-5. Window proxy 在 OOM 时泄漏
**文件**: `src/window.zig:72-78`  
**影响**: 僵尸窗口 — compositor 认为窗口存在但管理器丢失了引用

`add()` 失败时（OOM），pending window 从列表中移除但 `river_window` proxy 未被销毁：

```zig
add(wm.allocator, pending.*, ws.output, wm.getConfig()) catch |err| {
    std.debug.print("Failed to add window: {}\n", .{err});
    return;  // proxy 未销毁!
};
```

窗口对 compositor 仍然可见，但 rill-ed 已丢失对它的跟踪。

**修复**: 失败时调用 `river_window.destroy()`。

---

### C-6. `deinit` 不销毁 detached outputs 中的 window proxy
**文件**: `src/types.zig:86-89, 104-117`  
**影响**: 资源泄漏

`deinit()` 遍历 `detached_outputs` 时释放了 `former_output_name` 和 `window_list`，但未调用 `river_window.destroy()`。如果 `deinit()` 在 detached outputs 存在时被调用（如 panic 路径），window proxy 泄漏。

```zig
// types.zig:86-89 — 缺少 window.river_window.destroy()
for (self.pending_windows.items) |pending| {
    if (self.river_window_manager != null) {
        pending.river_window.destroy();  // pending 有，detached 没有
    }
}
```

**修复**: 在 `deinit()` 的 detached_outputs 循环中添加 `window.river_window.destroy()`（需检查 `river_window_manager` 非 null）。

---

## 3. 性能优化 (HIGH)

### P-1. 每次窗口事件全量扫描 O(outputs × 10 × windows)
**文件**: `src/window.zig:57-95, 104-120`  
**影响**: 每次 `.closed`/`.fullscreen_requested` 事件触发三重嵌套循环

每个窗口事件遍历所有输出 × 10 个工作区 × 所有窗口来匹配 `river_window` 指针。3 个输出、每个 5 个窗口 = 150 次指针比较。`session_unlocked`（`main.zig:159-184`）同样执行三重扫描。

**修复**: 在 `WindowManager` 中维护 `std.HashMap(*river.WindowV1, WindowLocation)`，插入/移除/移动时更新，查找 O(1)。

---

### P-2. `orderedRemove(0)` 导致 O(n²) 窗口迁移
**文件**: `src/layout.zig:235-243` (`reclaimOrphans`), `src/overview.zig:48-54`  
**影响**: 窗口数量多时性能退化

```zig
while (src_ws.window_list.items.len > 0) {
    var window = src_ws.window_list.orderedRemove(0); // 每次移位所有剩余元素
    ...
}
```

移除 N 个窗口需要 O(N²) 次元素移动。

**修复**: 由于所有窗口都被移动，直接传输 backing slice 所有权：
```zig
for (src_ws.window_list.items) |window| {
    dst_ws.window_list.append(allocator, window) catch { ... };
}
src_ws.window_list.deinit(allocator);
src_ws.window_list = .empty;
```

---

### P-3. `applyFocusAndBorders` 每帧遍历所有窗口
**文件**: `src/layout.zig:276-310`  
**影响**: 60fps 动画期间每秒遍历所有窗口 60 次

虽然 `sent_border_focused`/`sent_border_width` 缓存防止冗余协议调用，但遍历和比较本身仍在每帧执行。

**修复**: 维护 `needs_border_update` 标志，仅在焦点变化或配置变化时设置，动画期间仅遍历 dirty 窗口。

---

### P-4. 标题/APP_ID 事件每次触发堆分配
**文件**: `src/window.zig:99-110`  
**影响**: 浏览器标题频繁更新时的分配抖动

每次 `.title` 事件执行 1 free + 1 alloc + 1 memcpy。

**修复**: 使用小型 arena allocator 或固定大小内联缓冲区（128 bytes）+ 溢出时堆分配。

---

### P-5. `orphan_keys` 固定 16 项导致多显示器窗口丢失
**文件**: `src/layout.zig:253`  
**影响**: >16 个 detached outputs 时静默丢弃窗口

```zig
var orphan_keys: [16][]const u8 = undefined; // 超过 16 个 orphan 被忽略
```

**修复**: 使用 `std.ArrayList` 替代固定数组。

---

### P-6. `colorToRiver` 每帧重新计算
**文件**: `src/layout.zig:277-278`  
**影响**: 低 — 每帧 6 次浮点运算，但完全不必要

配置在动画期间不变，应在加载时预计算。

---

### P-7. `std.math.pow` 用于固定三次缓动
**文件**: `src/animation.zig:21`  
**影响**: 低 — 通用 pow 函数的开销大于手写乘法

```zig
// 当前
const eased = 1 - std.math.pow(f32, 1 - progress, 3);
// 优化
const t = 1 - progress;
const eased = 1 - t * t * t;
```

---

## 4. 架构改进 (MEDIUM)

### A-1. `layout.zig` 是 God Module（486 行，7+ 职责）
**文件**: `src/layout.zig`  
**影响**: 可维护性

`layout.zig` 包含：输出分离（`detachOutput`）、孤儿回收（`reclaimOrphans`）、工作区恢复（`restoreDetachedWorkspaces`）、焦点/边框应用（`applyFocusAndBorders`）、颜色转换（`colorToRiver`）、窗口吸附（`snapToFinish`）、完整 `apply()` 流程。输出迁移（~150 行）属于 `output.zig` 的职责。

**建议拆分**:
- `layout/apply.zig` — 几何计算
- `output-migration.zig` — detach/restore/reclaim
- `focus.zig` — 焦点和边框

---

### A-2. `layout.apply()` 承担 7+ 个独立职责
**文件**: `src/layout.zig:95-175`  
**影响**: 单一职责违反

`apply()` 依次执行：初始化 pending windows → 分离已移除输出 → 恢复/回收 detached 工作区 → 处理全屏/关闭状态 → 运行 layout 更新 → 应用焦点/边框 → 指针 warp。每个都是独立关注点。

---

### A-3. `layout.zig` 直接销毁 Wayland 协议对象
**文件**: `src/layout.zig:198-260`  
**影响**: 抽象泄漏

`detachOutput` 调用 `wl_output.destroy()`、`layer_shell_output.destroy()`、`river_output.destroy()`。布局模块应产生"需要移除的输出"数据结构，由 `output.zig` 执行销毁。

---

### A-4. `Status` 联合体无转换验证
**文件**: `src/types.zig:Status` + 6 个文件  
**影响**: 静默的非法状态转换

`Status` 在 `main.zig`、`keybinding.zig`、`seat.zig`、`output.zig`、`layout.zig` 中被修改，无集中式转换验证。`.animation → .pointer_action` 等非法转换静默发生。

**建议**: 添加 `Status.transition(next)` 方法或状态机模块。

---

### A-5. 错误处理不一致
**文件**: 多文件  
**影响**: 可预测性

| 路径 | 处理方式 |
|------|----------|
| config 加载失败 | `return error.ConfigLoadFailed`（致命） |
| output.add 失败 | `std.debug.print` + continue（静默） |
| window.add 失败 | `std.debug.print` + return（窗口丢失） |
| detachOutput temp key 失败 | 关闭所有窗口（破坏性回退） |
| reclaimOrphans append 失败 | `window.river_window.destroy()`（静默销毁） |

OOM 处理尤其不一致：`config.zig:26` panic，`overview.zig:45` 传播，`layout.zig:350` 静默销毁用户窗口。

---

### A-6. Config reload 非原子
**文件**: `src/keybinding.zig:397-414`  
**影响**: 短暂的不一致状态

`wm.config = new_config` 之后、下一个 `manage()` 之前，布局使用新配置但快捷键仍用旧配置。如果此时按键，布局计算和快捷键分发使用不同配置。

---

### A-7. `focus_output_*` 缺少 break
**文件**: `src/keybinding.zig:268-288`  
**影响**: 多输出重叠时焦点目标不正确

四个 `focus_output_*` 方向处理都未在首次匹配后 break，最后一个匹配的输出胜出而非第一个。

```zig
.focus_output_left => {
    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        // ...
        wm.focused_output_idx = target_output_idx;  // 无 break!
    }
},
```

**修复**: 添加 `break;`。

---

### A-8. `cloneConfig` 无 errdefer
**文件**: `src/config.zig:32-36`  
**影响**: OOM 路径内存泄漏

如果 `cloneKeybindings` 成功但 `clonePointerBindings` 失败，已克隆的 `keybindings` 泄漏。

```zig
fn cloneConfig(allocator: Allocator, cfg: types.Config) !types.Config {
    var cloned = cfg;
    cloned.keybindings = try cloneKeybindings(allocator, cfg.keybindings);
    cloned.pointer_bindings = try clonePointerBindings(allocator, cfg.pointer_bindings); // 失败时 keybindings 泄漏
    // ...
}
```

**修复**: 添加 `errdefer` 逐步释放已分配的部分。

---

## 5. 代码质量 (LOW)

### Q-1. 工作区数量 10 硬编码在多处
**文件**: `src/types.zig:121`, `src/keybinding.zig:183,188`, `src/overview.zig`  
**影响**: 维护负担

`[10]Workspace`、`if (ws.workspace_idx == 9) return` 等散落各处。应提取为 `const WORKSPACE_COUNT = 10;`。

---

### Q-2. `config.zig` 与 `keybinding.zig` 循环导入
**文件**: `src/config.zig:3`, `src/keybinding.zig:10`  
**影响**: 模块独立性

`config.zig` 导入 `keybinding.zig`（获取默认快捷键数据），`keybinding.zig` 导入 `config.zig`（实际未使用其函数，仅用 types）。Zig 允许循环导入，但降低了模块可推理性。

**修复**: `keybinding.zig` 移除对 `config.zig` 的导入。

---

### Q-3. `std.debug.print` 是唯一的错误报告机制
**文件**: 所有文件  
**影响**: 生产环境诊断困难

所有错误路径使用 `std.debug.print("...: {}\n", .{err})`，无结构化日志、无错误计数。seat 未找到、layer shell 绑定失败等协议错误无法产生可操作的诊断信息。

---

### Q-4. `animation.apply` 中 `now - start_time` 的精度问题
**文件**: `src/animation.zig:32-33`  
**影响**: 极低 — 动画时长通常 < 1 秒

如果 `now - start_time` 超过 `i32` 最大值（~2.1 billion ms ≈ 24 天），`@floatFromInt` 转 `f32` 会丢失精度。实践中不可能发生。

---

### Q-5. `output.name` 打印顺序误导
**文件**: `src/layout.zig:118-122`  
**影响**: 代码可读性

`output.name` 在第 121 行用于打印，第 122 行置 null。当前顺序正确（打印旧值），但结构上容易在重构时引入 bug。

---

### Q-6. `spawnDetached` 的 `exit(1)` 跳过清理
**文件**: `src/spawn.zig:35, 41`  
**影响**: 极低 — 进程即将终止

第一子进程在 `setsid` 失败时调用 `exit(1)` 而非清理 Wayland FD。内核会关闭 FD，但跳过 atexit 处理器。

---

### Q-7. `config.reload` 的 fallback 行为与 `load` 不一致
**文件**: `src/config.zig:12 vs 92`  
**影响**: 用户体验

`load` 在找不到配置文件时回退到默认值（始终成功）。`reload` 找不到文件时返回 null（静默失败）。用户可能不知道配置被忽略了。

---

### Q-8. 无多 seat 支持
**文件**: `src/types.zig:40`, `src/main.zig:184-196`  
**影响**: 仅影响多输入设备场景

`wm.river_seat` 存储单个 seat，第二个 seat 的事件被覆盖忽略。

---

### Q-9. `PR_SET_PDEATHSIG` 在父进程 exec 时可能误触发
**文件**: `src/main.zig:39-44`  
**影响**: 极低 — 仅在 `river -c rill` 且 river 被替换时

如果 river 被另一个进程 exec 替换，父 PID 变化触发 `PR_SET_PDEATHSIG`，rill-ed 被提前终止。

---

## 6. 优化路线图

### Phase 1: 安全修复（1-2 天）

| # | 问题 | 修复复杂度 | 文件 |
|---|------|-----------|------|
| C-1 | SIGPIPE 处理 | 5 行 | `main.zig:28` |
| C-5 | Window proxy OOM 泄漏 | 3 行 | `window.zig:72` |
| A-7 | focus_output 缺少 break | 4 行 | `keybinding.zig:268-288` |
| A-8 | cloneConfig errdefer | 15 行 | `config.zig:32-36` |

### Phase 2: 协议合规（2-3 天）

| # | 问题 | 修复复杂度 | 文件 |
|---|------|-----------|------|
| C-3 | focused_output_idx 外修改 | 中等 — 需重新设计 output removal 流程 | `output.zig:104-118`, `layout.zig` |
| C-4 | layout.update 外调用 | 低 — 替换为 status + manageDirty | `output.zig:130` |
| C-6 | deinit detached proxy 泄漏 | 10 行 | `types.zig:104-117` |

### Phase 3: 内存安全（3-5 天）

| # | 问题 | 修复复杂度 | 文件 |
|---|------|-----------|------|
| C-2 | Overview 索引失效 | 高 — 需重新设计 origins 记录方式 | `overview.zig` |
| P-5 | orphan_keys 固定数组 | 低 — 替换为 ArrayList | `layout.zig:253` |

### Phase 4: 性能优化（1-2 周）

| # | 问题 | 修复复杂度 | 文件 |
|---|------|-----------|------|
| P-1 | 窗口事件全量扫描 | 中等 — 添加 HashMap 索引 | `types.zig`, `window.zig`, `main.zig` |
| P-2 | orderedRemove O(n²) | 低 — 批量传输 | `layout.zig:235`, `overview.zig:48` |
| P-3 | 每帧焦点遍历 | 中等 — dirty 标志 | `layout.zig:276` |
| P-4 | 标题分配抖动 | 中等 — arena 或 inline buffer | `window.zig:99` |

### Phase 5: 架构重构（2-4 周）

| # | 问题 | 修复复杂度 | 文件 |
|---|------|-----------|------|
| A-1 | layout.zig 拆分 | 高 — 需重新组织模块边界 | `layout.zig` → 多文件 |
| A-4 | Status 状态机验证 | 中等 — 添加 transition 方法 | `types.zig`, 多文件 |
| A-5 | 错误处理统一 | 中等 — 定义错误分类 | 全局 |
| A-6 | Config reload 原子性 | 中等 — 添加 generation counter | `keybinding.zig`, `types.zig` |

---

## 附录: 评审视角交叉验证

以下问题被多个独立评审同时发现，置信度高：

| 问题 | 评审 1 | 评审 2 | 评审 3 | 评审 4 |
|------|--------|--------|--------|--------|
| Overview 索引失效 | ✅ #1 | — | — | ✅ #14 |
| focus_output 缺少 break | ✅ #9 | — | — | ✅ #25 |
| orphan_keys 固定 16 | ✅ #3,#15 | — | — | — |
| cloneConfig 无 errdefer | ✅ #5 | — | ✅ 5.3 | — |
| 全量扫描窗口 | — | ✅ #2 | — | — |
| orderedRemove O(n²) | — | ✅ #1 | — | — |
| layout.zig god module | — | — | ✅ 1.3 | — |
| Status 无验证 | — | — | ✅ 6.1 | — |
| 协议外状态修改 | — | — | ✅ 7.1 | ✅ #2,#3 |
| SIGPIPE 缺失 | — | — | — | ✅ #15 |
| Window proxy 泄漏 | — | — | — | ✅ #18 |
