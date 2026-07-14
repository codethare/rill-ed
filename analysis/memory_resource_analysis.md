# 内存与资源生命周期分析（rill-ed）

## 分析方法
- 完整阅读 `src/types.zig`、`src/window.zig`、`src/output.zig`、`src/layout.zig`、`src/config.zig`、`src/spawn.zig`、`src/animation.zig`、`src/main.zig` 及关键辅助文件。
- 用 `zig build` 与 `zig build test` 做基线验证（均通过）。
- 重点检查：allocator 配对、`catch` 错误处理、`orelse return` / `.?` 解包、detach/restore 对称性、pending_windows 积压、reload_config 旧资源释放、字符串/切片所有权。

---

## 问题清单

### 1. `src/config.zig:21-23` — CRITICAL — 默认回退 Config 的静态切片会被 `parse.free` 释放
- **描述**：`load()` 在没有配置文件时 `allocator.create(types.Config)` 并把 `.{}` 赋值给它。`.{}` 中的 `keybindings`、`pointer_bindings` 指向 `types.default_keybindings` / `default_pointer_bindings` 等静态只读切片。`WindowManager.deinit` 与 `config.reload` 均按文档调用 `std.zon.parse.free(allocator, config)`，会尝试用堆分配器释放静态切片。
- **根因**：默认结构体的切片字段不是由分配器分配的，`parse.free` 仍会对它们调用 `allocator.free`。
- **修复方向**：回退路径中把静态默认值深拷贝为分配器拥有的切片（`allocator.dupe` 复制 `default_keybindings`、`default_pointer_bindings`、`spawn_at_startup`），或让 `load()` 直接解析一段内存中的默认 ZON 字符串，确保所有权一致。

### 2. `src/layout.zig:88` — MAJOR — 多个输出同时移除时会覆盖并泄漏 `detached_workspaces`
- **描述**：当所有输出都被标记为 `is_removed` 且没有存活迁移目标时，`apply()` 的 `else` 分支把当前被移除输出的 `workspace_list` 直接赋给 `wm.detached_workspaces`。若同时有两个以上输出被移除，后一个输出会覆盖前一个保存的数组，导致前一个 `detached_workspaces` 里 10 个 `window_list` 的 backing memory 泄漏。
- **根因**：未检查 `wm.detached_workspaces` 是否已存在并先释放旧数据。
- **修复方向**：在赋值前先 `if (wm.detached_workspaces) |*detached| deinit 所有 workspace.window_list`；或者把多个移除输出的窗口合并到同一组 detached workspaces 中。

### 3. `src/main.zig:156` — MAJOR — `.finished` 销毁 `river_window_manager` 后未清空指针
- **描述**：`windowManagerListener` 对 `.finished` 只调用 `window_manager.destroy()`，没有设置 `wm.river_window_manager = null`。主循环与 `.setup_bindings`、`.exit` 等分支随后可能通过 `wm.river_window_manager.?` 访问已释放对象。
- **根因**：销毁协议对象后没有使本地引用失效。
- **修复方向**：`window_manager.destroy(); wm.river_window_manager = null;`；并在访问处加 null 防护，避免断开连接后的 use-after-free。

### 4. `src/window.zig:15-26` — MAJOR — `.dimensions` 失败或输出不可用时 pending_windows 残留
- **描述**：`windowListener` 处理 `.dimensions` 时，若 `focused_output_idx == null` 直接 `return`，或在 `add()` 失败后 `return`，都不把对应的 `river.WindowV1` 从 `layout.pending_windows` 移除。该条目会一直保留在数组中；如果后续再也找不到匹配输出，数组只会在进程退出时释放，期间重复收到同一窗口的 dimensions 事件会反复尝试 `add()`。
- **根因**：`pending_windows` 的移除逻辑只在 `add()` 成功后执行。
- **修复方向**：明确错误策略：
  - 若 `focused_output_idx` 为 null，可保留条目等待输出出现；
  - 若 `add()` 失败（OOM / `getNode()` 失败），应 `destroy` 该 `river_window` 并 `swapRemove`，避免无效重试。

### 5. `src/types.zig:51-52` / `src/types.zig:65` — MAJOR — `deinit` 未销毁 Wayland 协议对象
- **描述**：`WindowManager.deinit()` 仅调用 `xkb_binding_list.deinit()` 与 `pointer_binding_list.deinit()` 释放数组 backing memory，但没有遍历条目调用 `river_xkb_binding.destroy()` / `river_pointer_binding.destroy()`。`output_list.deinit()` 也只释放输出数组，没有销毁 `river_output` 或 `river_layer_shell_output`。虽然服务器在断开时会清理，但客户端主动释放是正确所有权实践；reload 时虽然 `setupKeybindings/setupPointerBindings` 会销毁旧绑定，但进程退出路径遗漏。
- **根因**：deinit 只释放 Zig 端容器，未释放容器内引用的协议对象。
- **修复方向**：在 `WindowManager.deinit` 中先销毁 `xkb_binding_list` / `pointer_binding_list` 内的协议对象，再释放容器；对 `output_list` 中的 `river_output` / `river_layer_shell_output` 调用 destroy（或确认服务器所有权后文档化）。

### 6. `src/main.zig:122` / `src/registryListener` — MINOR — 协议绑定失败被静默吞掉
- **描述**：`registry.bind(..., catch null)` 与 `output.add(..., wm) catch |err| std.debug.print(...)` 把错误转为 null 或日志。若 `river_window_manager` / `river_seat` / `river_layer_shell` 绑定失败，后续代码大量使用 `.?` 解包，会 panic。
- **根因**：错误路径没有让程序体面退出或回滚已部分创建的状态。
- **修复方向**：绑定失败时直接打印错误并 `return`，避免带着 null 核心指针进入主循环。

### 7. `src/layout.zig:63` / `src/layout.zig:78` / `src/overview.zig:171` — MINOR — append/insert 失败时仅销毁协议对象，未清理源列表中的残留引用
- **描述**：`target_ws.window_list.append(...) catch { window.river_window.destroy(); }` 等写法在分配失败时销毁 Wayland proxy，但源 workspace 的 `window_list` 仍持有同一个 `Window` 对象，直到 `src_ws.window_list.deinit()` 才释放数组内存。虽然当前 `Window` 没有其他需释放的资源，但这种模式容易在将来引入重复释放或悬空引用。
- **根因**：错误处理只处理了协议对象，没把窗口从源列表安全移除。
- **修复方向**：统一写一个"迁移窗口"辅助函数：从源列表取出、目标列表插入，任何一步失败都回滚（把窗口放回源列表或销毁 proxy 并从源列表移除），避免半迁移状态。

### 8. `src/keybinding.zig:398,426,454,482` / `src/layout/scroller.zig:66` — MINOR — 对刚由本函数设置的值使用 `.?` 解包
- **描述**：`moveWindowToWorkspace` 成功后设置 `target_workspace.focused_window_idx`，调用方立即用 `.?` 读取。`scroller.zig` 中 `anchor_idx` 也是刚由循环 break 得到即 `.?` 解包。只要前面逻辑不变就不会 panic，但把不变性依赖放在 `.?` 上增加了未来重构风险。
- **根因**：用 `.?` 表达"我知道这一定不是 null"，缺少更明显的断言或条件检查。
- **修复方向**：将 `.?` 改为 `orelse unreachable`（带注释）或改用 `if` 分支，使假设显式化。

### 9. `src/config.zig:35-43` — MINOR — `reload()` 在旧 config 为静态默认时会重复触发问题 1
- **描述**：`reload()` 先 `std.zon.parse.free(allocator, old_config)`。如果当前配置正是问题 1 中的默认回退对象，释放静态切片会崩溃。
- **根因**：与问题 1 同源。
- **修复方向**：修复问题 1 后自然消失；或者 `reload()` 前判断配置是否为 allocator-owned（如通过 sentinel bool）。

### 10. `src/output.zig:30-33` — INFO — restore 时覆盖新 output 的 workspace_list，但未销毁旧空列表
- **描述**：`output.add()` 把 `detached.*` 直接赋给 `restored.workspace_list`，覆盖了刚创建的 10 个空 `ArrayList(.empty)`。空 ArrayList 无需释放，因此当前安全。但如果未来 `Workspace` 加入初始化时即分配的资源，这里会泄漏。
- **根因**：restore 直接覆盖数组，未先 deinit 被覆盖的 workspace_list。
- **修复方向**：restore 前先遍历并 `deinit` 目标 `workspace_list`，再赋值；即使当前为空也无害。

### 11. `src/spawn.zig:14` / `src/spawn.zig:69` — INFO — 进程启动错误处理合理
- **描述**：`spawnDetached` 使用 arena，父进程退出时 arena 释放；子进程失败则 `_exit`。`execveSearch` 的 `catch continue` 在 PATH 遍历中是正确语义。
- **根因**：无。
- **修复方向**：无需修改。

---

## 优先级排序（1 = 最高）

1. **问题 1：默认回退 Config 的静态切片释放风险（CRITICAL）**
   - 影响启动/退出/重载三条路径，可能导致进程退出或首次 reload 时崩溃；修复后可避免 UB。
2. **问题 2：`detached_workspaces` 覆盖泄漏（MAJOR）**
   - 多输出 TTY 切换场景下会泄漏整组窗口 backing memory，属于实际内存泄漏。
3. **问题 3：`.finished` 后悬空 `river_window_manager` 指针（MAJOR）**
   - 断开连接或 compositor 结束时会触发 use-after-free，轻则崩溃，重则安全类问题。

其余 MAJOR/MINOR 可在上述三项修复后按序处理。

---

## 验证

- `zig build`：通过
- `zig build test`：通过
- 以上问题均来自静态代码分析，未引入代码变更。
