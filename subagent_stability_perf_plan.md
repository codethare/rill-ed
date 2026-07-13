# 多 subagent 稳定性与性能优化方案分析

## 范围
对 `src/`（15 文件 / ~2600 行 Zig，river 派生 WM）做稳定性与性能优化方案，评估并设计多 subagent 分工。

## 代码现状
- 单例状态机 `WindowManager.status`，串行 `display.dispatch` 事件循环，无并发。
- 已有手工分析：`focus_analysis.md`（TTY 切回焦点流）、`keybinding_analysis.md`。
- 构建验证：`zig build` / `zig build test`（test 仅 `refAllDecls`，无真实用例）。
- 性能面：每帧 `animation.apply`、每次 `manage` 的 `pending_windows.append`、`getConfig()` 浅拷贝、keybinding/pointer setup 分配。
- 稳定性面：大量 `catch |err| std.debug.print` 错误吞噬、`orelse return`、`.?` 解包、`detached_workspaces` 生命周期、reload_config 重入、协议事件顺序（dimensions 晚于 manage_start）。

## 是否值得多 subagent
代码库小且文件都耦合到 `types.zig`，大规模 fan-out 是反模式：并行写必冲突，并行读重复成本高。
合理定位：**只做只读 fan-out 分析，绝对单写**。稳定性与性能两视角并行交叉评审有价值；实现交给单 worker 串行改且每步构建验证。

## 推荐分解

共享上下文（每个 agent prompt 必须内嵌，subagent 无项目上下文）：
- Zig 0.16 / `std.Io` / `std.ArrayList` 新 API（`.empty` / `.append(allocator, ...)` / `.deinit(allocator)`）。
- 协议顺序先读 `protocol/river-window-management-v1.xml`：manage_start 先于 dimensions/render。
- 先读 `focus_analysis.md` / `keybinding_analysis.md`，不重复结论。
- Wayland API 以 `.zig-cache` 生成的 `wayland.zig` stub 为准，禁止臆造。

| Phase | Agent (tier) | 任务 | 产出 |
|---|---|---|---|
| 1 并行 | A scout small | 稳定性侦察：错误吞噬、`orelse return`、`.?`、append 静默失败、ArrayList deinit 配对、detach 生命周期 | risk list |
| 1 并行 | B scout small | 性能侦察：每帧/每次 manage 的分配与拷贝、热路径标注 | hot-path list |
| 2 并行 | C reviewer medium | 深评 lifecycle/内存：`types.deinit`、`window.zig`、`output.zig`、detach/restore 对称、reload 时旧 binding 释放 | 带严重度 issue 集 |
| 2 并行 | D reviewer medium | 深评 layout/animation 主循环：数学、f32 插值与时钟漂移、`manageDirty` 每帧、`needs_refocus` 重入、reload 重入 | 同上 |
| 3 | reviewer big | 交叉验证 C+D+已有分析，删误报，标根因是否在共享函数、连累其它调用者 | 去重 ordered fix list |
| 4 | planner medium | 出最小 diff / 根因修复的实施步骤，每步附验收（build/test/手测） | 实施计划 |
| 5 串行单写 | worker medium（或父 agent） | 按计划顺序改，每改一个跑构建+测试，失败回退 | 改动 |

## 约束与风险
1. **一个写者**：Phase 5 绝不并行多写，避免 `types.zig` 多方同改。
2. **不要大 fan-out**：每 agent 都要读全 `types.zig`+`main.zig`，重复成本不可避免，故 agent 数压到 4。
3. **协议时序是稳定性根因大头**：Phase 2 D 必须读 `protocol/*.xml` + `focus_analysis.md`，否则会建议违反「dimensions 晚于 manage_start」的错误修复。
4. **性能改动不能动错误路径**：Phase 3 verify 专门拦截（如 append 改预分配仍要保留 `catch` 语义）。
5. **守 AGENTS.md / ponytail**：不新增接口/工厂/配置项/防御代码；fix list 中出现此类一律 Phase 3 砍掉。
6. **测试基建薄弱**：无微基准，纯微优化是猜。只保留有明确收益项（消除每帧分配、消除拷贝），其余列「需基准再加」。

## 建议跳过 / 二期
- 纯微优化（f32/f64、循环展开、内联）——无基准前不动。
- ArenaAllocator 替换单点分配——收益不明，改动面大，二期评估。
- Config copy-on-write / 缓存——浅拷贝 slice 指针成本可忽略，YAGNI。
- 自动生成 `test_*.zig` 套件——现有基建不支持，多为噪音。

## 启动选项
- 仅分析：workflow 背景跑 Phase 1–4，回传后人工决定是否进入 Phase 5。
- 小步试探：只跑 Phase 1 + 3，先确认有真问题再展开。