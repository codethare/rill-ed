# 设计规划：垂直生成模式（垂直滚动条）

## 需求

- 增加一个模式：激活后，新生成的窗口在焦点窗口的**垂直方向**生成（堆叠在其下方，成为新的焦点窗口）。
- 行为为**开关**：激活一次 → 垂直生成；再次激活 → 回复水平生成（当前 scroller 行为）。
- 不修改主要源文件。本文件仅为方案报告。

---

## 现状架构（与该需求相关的关键事实）

| 事实 | 位置 | 说明 |
|------|------|------|
| 布局枚举 | `types.zig` `Layout = enum { scroller, floating }` | 每个 Workspace 一个，per-workspace |
| 滚动条是横轴的 | `scroller.zig` `apply` | 焦点窗锚定 `current.x`，其余窗按 x 左右排列；y 固定为 `non_exclusive.y + vertical_gap` |
| 新窗插入位置 | `window.zig` `add()` | 永远 `focused_window_idx + 1`，并立即把 `focused_window_idx` 指向新窗 |
| 新窗初始框 | `layout/common.zig` `initialRectangle` | 落在输出右边缘：`x = non_exclusive.x + width - w`，全高 `height - 2*vertical_gap` |
| 尺寸语义 | `Window.proportion`（f32） | 表示「占可用**宽度**的比例」；`adjust_window_width` / `set_window_width` |
| 水平焦点/移动 | `actions.zig` | `focus_window_left/right`、`move_window_left/right`（索引 ±1） |
| 工作区焦点 | `actions.zig` | `focus_workspace_above/below` 已绑定 `Super+Up/Down` |
| 窗口级上下焦点 | — | **不存在**。`focus_window_above/below` / `move_window_above/below` 全无 |
| 几何辅助 | `scroller.zig` `focusedWindowLayout` / `unfocusedWindowLayout` / `snapToEdge` | 全部硬编码横轴（x / width / horizontal_gap） |
| 切换类动作范例 | `keybinding.zig` `toggle_workspace_floating` | 翻 `Window.is_floating`，调用 `layout.update` |
| `placeWindow`/裁剪 | `layout/common.zig` | 按轴无差别比较 left/right/top/bottom，**对纵轴滚动天然兼容**，无需改 |
| 工作区纵向偏移 | `layout.zig` `update` 的 `y_offset` | 用于工作区切换动画；与窗口纵向排列相加——可叠加，无需改 |

**核心结论**：当前 scroller 是一条**单向 1D 滚动条**，把轴从 x 换成 y 是该模型的最小对称扩展。新窗插入逻辑（索引 `focused+1`）本身与轴无关，改的只是布置几何与导航。

---

## 方案对比

### 方案 1（推荐）：给 scroller 增加一个 orientation，per-workspace

- `Workspace` 增加字段 `orientation: enum { horizontal, vertical }`（默认 `.horizontal`）。
- 新增 `KeybindingAction.toggle_window_orientation`（或 `toggle_strip_orientation`），翻当前 workspace 的 orientation 并 `layout.update`。
- `scroller.apply` 按 orientation 分支：
  - `.horizontal`：现有代码。
  - `.vertical`：把 x↔y、width↔height、horizontal_gap↔vertical_gap 互换的镜像实现。
- 新窗插入索引不变；只是 `.vertical` 下 `add()` 用纵向版初始框（落在焦点窗下方）。
- **优点**：与现有 per-Workspace `Layout`/`is_floating` 模式一致；状态局部、可热重载； Toggle 语义清晰（flip orientation）。
- **缺点**：`scroller.apply` 的几何分支变重，需引入轴抽象（见下「几何抽象」）。

### 方案 2：bool `vertical_generation` 字段，独立于 Layout

- `Workspace.vertical_generation: bool = false`。
- scroller.apply 据此 bool 决定轴；其余同方案 1。
- **优点**：不污染 `Layout` 枚举，diff 最小。
- **缺点**：bool 与 `Layout` 是两套正交状态（vertical 可与 floating 叠加？需定义取舍）。语义略弱于 enum。

### 方案 3：新增 `Layout.stack`（master-stack 垂直堆叠）

- 焦点窗为主、其余窗在侧栏纵向堆叠（或纵向 dwindle）。
- **优点**：是另一种成熟布局。
- **缺点**：不是「窗口在焦点窗的垂直方向生成」的纯滚动语义，几何模型完全不同，工作量大、偏离需求。**不推荐作为本期方案**，可作为后续独立布局。

### 方案 4：WindowManager 级全局 orientation toggle

- 单一 `wm.vertical_mode: bool`，一次翻转所有 workspace。
- **优点**：状态最简。
- **缺点**：与现有 per-workspace 局部状态哲学不一致；无法「某工作区横、某工作区纵」。需求未明确要求全局，故 per-workspace 更灵活且更符合既有设计。

---

## 推荐方案：方案 1 的落地要点（仅设计，不落码）

### 1. 状态
- `types.zig` `Workspace`：加 `orientation: enum { horizontal, vertical } = .horizontal`。
- 可选 `Config`：加 `default_orientation`（默认 `.horizontal`），供 `config.zig`/新建 workspace 初值。

### 2. 动作与绑定
- `actions.zig`：加 `toggle_window_orientation: void`（或 `toggle_strip_orientation`）。
- `keybinding.zig`：实现分支：翻 `workspace.orientation`，`layout.update(...)`；后续 `wm.status = .layout`。
- `config.zig`/`config.new.zon`：给一个默认键（如 `Super+g`，因 `Super+v` 已被 `toggle_workspace_floating` 占用——见冲突点）。

### 3. scroller.apply 轴分支
为避免两份近似实现漂移，**推荐轴抽象**而非复制粘贴：
- 引入一个内部小 helper，把 `Rectangle.{x,y,width,height}` 与 gap 沿「主轴 / 交叉轴」区分。
- `.horizontal`：主轴 = x/width，主 gap = `horizontal_gap`，交叉 = 全高。
- `.vertical`：主轴 = y/height，主 gap = `vertical_gap`，交叉 = 全宽。
- `focusedWindowLayout` / `unfocusedWindowLayout` / `snapToEdge` 改为按主轴/交叉轴布置；`should_center`、全屏逻辑不变。
- `ponytail:` 注记：单一 orientation 分支 + 复用现有 boxed-rectangle 模型，避免双份实现。

### 4. 新窗插入与初始框
- `window.zig` `add()`：插入索引 `focused+1` 不变；初始框按 orientation 选择 —— 给 `common` 增加纵向版 `initialRectangleVertical`（落在 `non_exclusive.y + height - h`，全宽）或把 `initialRectangle/centerRectangle` 参数化为 orientation。
- `.vertical` 下「新窗垂直生成」：新窗落在焦点窗**下方**（主轴 + 方向），焦点切换到新窗——与现有「新窗落在右方并取焦点」对称。

### 5. 尺寸语义（proportion）
- `proportion` 在 `.vertical` 改解为「占可用**高度**的比例」。
- `adjust_window_width` / `set_window_width` 动作名在纵向下语义偏移。两条路线：
  - **A（最小改）**：复用同一动作，纵向下调整 proportion 即调整高度，仅动作名欠准。
  - **B（更整齐）**：加 `adjust_window_size` / `set_window_size` 泛化动作，按当前 orientation 调对应轴；保留旧名作别名以兼容既有配置。

### 6. 导航与新键位（**最关键的冲突点**）
现状：`Super+Up/Down` = 切换 workspace；无窗级上下焦点。垂直模式下必须能沿纵轴在窗口间移动焦点。
备选：
- **a. 新增窗级上下导航动**作 `focus_window_above` / `focus_window_below` / `move_window_above` / `move_window_below`（实现等同 `focus_window_left/right`，索引 ±1），绑定独立键（如 `Super+j/k`、`Super+bracketleft/right`、`Super+comma/period`）。与 workspace 的 Up/Down 不冲突。**推荐**。
- **b. orientation 感知的键位重映射**：垂直模式下把 `Super+Up/Down` 临时改为窗级 focus，workspace 切换改走 `Shift+Up/Down`。状态相关、更易混乱，**不推荐**。
- 注意 `focus_window_or_output_left/right` 这类「到边→切输出」的组合模式也应补 `..._above/below` 对应物，保持一致。

### 7. 无需改动处（确认）
- `layout/common.zig` `placeWindow`：可见性与裁剪按轴无差别，纵轴滚动天然兼容。
- `layout.zig` `update` 的 workspace `y_offset`：与窗口纵向布置可叠加。
- `window.zig` 插入索引与 `former_output_name` 迁移逻辑：与轴无关。

---

## 风险与边界

| 风险 | 说明 | 缓解 |
|------|------|------|
| 键位冲突 | `Super+v` 已用于浮动；`Super+Up/Down` 已用于 workspace | 选未占用键（如 `Super+g` 切换 orientation、`Super+j/k` 纵向窗级 focus） |
| 动作命名语义漂移 | `adjust_window_width` 在纵向下实为高度 | 泛化为 `*_window_size`，旧名作兼容别名 |
| 几何代码重复漂移 | 直接复制 horizontal 改 vertical 易双方分叉 | 主轴/交叉轴 helper 统一 |
| `center_focused_window = .single` 计数 | 已按 tiled_count，与轴无关 | 无需改 |
| 工作区切换动画 y_offset 与纵向滚动叠加 | 视觉上 workspace 纵向滑动 + 内部纵向滚动条 | 按 box 相加，符合既有模型，但需实测滚动定位不串位 |
| overview/锁屏/多输出迁移 | orientation 是 per-workspace 字段，随 workspace 整体迁移/保存 | 与 `Layout` 同生命周期，自动一致 |
| 动画 | `window.start/finish` 框差值轴无关 | 无需改 |

---

## 落地清单（实现时按序，本报告不含代码改动）

1. `types.zig`：`Workspace.orientation` 字段 + 可选 `Config.default_orientation`。
2. `actions.zig`：`toggle_window_orientation`；可选 `focus_window_above/below`、`move_window_above/below`、泛化 `*_window_size`。
3. `layout/common.zig`：`initialRectangle` / `centerRectangle` 参数化 orientation（或加 vertical 版）。
4. `layout/scroller.zig`：主轴/交叉轴抽象，`focusedWindowLayout`/`unfocusedWindowLayout`/`snapToEdge` 按 orientation 分支；补纵向测试。
5. `keybinding.zig`：`toggle_window_orientation` 分支；纵向导航分支（若采用方案 6a）。
6. `config.zig` / `config.new.zig`：默认键位 + `default_orientation` 解析；reload 兼容。
7. `README.md`：默认键位表增列。

---

## 推荐取舍一览

- **状态位置**：per-Workspace `orientation` enum（方案 1）。
- **新窗方向**：下方（主轴正方向，与「右方」对称）。
- **导航**：新增 `focus_window_above/below` + `move_window_above/below`，独立键位（方案 6a）。
- **尺寸**：`proportion` 按轴重解释，动作泛化为 `*_window_size`（兼容旧名）。
- **几何**：主轴/交叉轴 helper，避免双份实现。