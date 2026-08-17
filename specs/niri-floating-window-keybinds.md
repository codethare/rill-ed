# niri Floating 窗口的键盘移动与缩放

> 面向 AI 的技术资料整理。所有事实均经 niri 源码（main 分支）逐行核验，行号随文标注；版本信息见「版本与来源」。用途:给需要集成 niri 浮窗控制的 agent/脚本提供精确、无歧义的 API 与配置事实。

## 1. 结论速览

| 需求 | 支持情况 | 关键 action |
|---|---|---|
| 键盘方向移动 floating 窗口 | ✅ 支持（25.01 起） | `move-window-left/right/up/down`、`move-window-*-or-to-workspace-*` |
| 键盘精确定位/偏移 | ✅ 支持，但**不能直接写进 binds** | `move-floating-window`（仅 IPC，需 spawn 包装） |
| 键盘缩放（像素/百分比） | ✅ 支持 | `set-window-width` / `set-window-height` |
| 键盘循环预设尺寸 | ✅ 支持 | `switch-preset-window-width/height`（+ Back 变体） |
| 居中 | ✅ 支持 | `center-window` |
| 重置高度 | ❌ 对 floating 无效 | `reset-window-height`（平铺概念） |
| 最大化 | ⚠️ 非缩放：会先转平铺再最大化 | `maximize-window-to-edges` |

判定规则（源码统一逻辑）：焦点在 floating 布局（`floating_is_active`）时，`move-window-*`、`set-window-width/height`、`switch-preset-window-*`、`center-window` 等动作自动作用于当前 floating 窗口；`reset-window-height`、`consume-or-expel-*` 则对 floating 显式短路（no-op）。

## 2. 键盘移动（Move）

### 2.1 方向移动（推荐）

- 触发条件：焦点在 floating 窗口上（用 `Mod+V` 转浮窗、`Mod+Shift+V` 切换浮窗/平铺焦点）。
- 每次触发移动 **50 逻辑像素**（`DIRECTIONAL_MOVE_PX = 50.`，`src/layout/floating.rs:32`），按住触发 repeat（binds 默认 repeat）。
- 路由链路：`Action::MoveWindowDown/Up/... → layout.move_down()/move_up() → workspace.move_*() 判断 floating_is_active → floating.move_left/right/up/down()`（`src/layout/workspace.rs:1042-1099`、`src/layout/floating.rs:948-962`）。`move-window-down-or-to-workspace-down` / `move-window-up-or-to-workspace-up` 同样作用于 floating（社区 25.11 用户实测确认，discussion #3431）。
- 步长 50px **硬编码、不可配置**；需要自定义步长只能走 2.2 的 `move-floating-window` + spawn。

配置示例：

```kdl
binds {
    Mod+Ctrl+H { move-window-left; }    // 默认配置未绑左右，需自加
    Mod+Ctrl+L { move-window-right; }
    Mod+Ctrl+J { move-window-down; }    // 默认配置已绑
    Mod+Ctrl+K { move-window-up; }      // 默认配置已绑
}
```

### 2.2 精确移动/定位（`move-floating-window`）

- 功能：设置绝对坐标、绝对/相对像素偏移、绝对/相对工作区百分比。
- **关键限制**：配置层 action 变体 `MoveFloatingWindowById` 标记为 `#[knuffel(skip)]`（`niri-config/src/binds.rs:350`），**不能直接写入 `binds {}`**（直接写会解析失败）；只能经 `niri msg action`（IPC）调用。
- 参数语义（`PositionChange`，`niri-ipc/src/lib.rs:965-974`）：

| 写法 | 含义 |
|---|---|
| `+10` / `-10` | 相对当前坐标偏移 ±10px |
| `10` | 绝对坐标设为 10px |
| `+10%` / `-10%` | 相对偏移 ±10%（按工作区） |
| `10%` | 绝对坐标设为工作区的 10% |
| `--id N` | 指定窗口（默认焦点窗口） |

- 边界行为：位置会夹在工作区内、避免漂出屏幕（25.01 release notes 明确说明）。

命令与键位包装：

```bash
# 相对偏移（注意 + 号需引号包裹，防止 shell 吞掉）
niri msg action move-floating-window -x +100 -y -50
# 绝对坐标
niri msg action move-floating-window -x 100 -y 200

# IPC 的 --id / --x / --y 全名风格亦可
niri msg action move-floating-window --id 5 --x "+10" --y "0"
```

```kdl
// binds 中包装 IPC（spawn 不开 shell，参数需逐个拆分）
binds {
    Mod+Ctrl+NumpadAdd { spawn "niri" "msg" "action" "move-floating-window" "-x" "+10"; }
    Mod+Ctrl+NumpadSubtract { spawn "niri" "msg" "action" "move-floating-window" "-x" "-10"; }
    // 需要 shell 语法时代替方案
    Mod+Ctrl+Shift+NumpadAdd { spawn-sh "niri msg action move-floating-window -x +10"; }
}
```

## 3. 键盘缩放（Resize）

- 路由链路：焦点为 floating 时 `Action::SetWindowWidth/Height → layout.set_window_width/height → workspace.set_window_width/height 判断 floating → floating.set_window_width/height(window, change, animate)`（`src/layout/workspace.rs:1204-1222`、`src/layout/floating.rs:754/801`）。
- 参数语义（`SizeChange`，与 PositionChange 同构，`niri-ipc/src/lib.rs:1777`）：

| 写法 | 含义 |
|---|---|
| `"+10%"` / `"-10%"` | 相对缩放 ±10%（按工作区） |
| `"1000"` | 绝对尺寸 1000px |
| `"+100"` / `"-100"` | 相对 ±100px |
| `"10%"` | 绝对尺寸 = 工作区 10% |

- 行为约束：受窗口自身 min/max size 约束；缩放值被夹在 `MAX_PX=100000` / `MAX_F=10000` 内，且最终尺寸不超出工作区；手动 set 后清除 preset 索引，后续 `switch-preset-*` 从下一个预设开始轮换。

```kdl
binds {
    // 相对缩放
    Mod+Ctrl+Equal  { set-window-height "+10%"; }   // 默认配置同款（Mod+Shift+Equal）
    Mod+Ctrl+Minus  { set-window-height "-10%"; }   // 默认配置同款（Mod+Shift+Minus）
    Mod+Ctrl+Plus   { set-window-width  "+100"; }
    Mod+Ctrl+Shift+Plus  { set-window-width "-100"; }
}
// IPC 精确缩放到指定窗口
niri msg action set-window-width 1200
niri msg action set-window-width --id 5 "-10%"
```

### 3.1 预设尺寸循环

- `switch-preset-window-width/height`（及 Back 反向）循环 `layout { preset-column-widths }` / `layout { preset-window-heights }` 中配置的预设，floating 同样适用（`floating.toggle_window_width/height`，`src/layout/floating.rs:640/701`）。
- 默认绑定：仅 `Mod+Ctrl+Shift+R { switch-preset-window-height; }`（宽度无默认绑定，需自加）。

```kdl
layout {
    preset-window-heights { 30.0%; 50.0%; 70.0%; }
    preset-column-widths  { 20.0%; 40.0%; 60.0%; }
}
binds {
    Mod+Ctrl+Shift+R { switch-preset-window-height; }
    Mod+Ctrl+Shift+T { switch-preset-window-width; }
}
```

## 4. 相关要点与坑

- `reset-window-height`：命中 floating 直接 return（`src/layout/workspace.rs:1224-1231`），**对 floating 无效果**。
- `maximize-window-to-edges`：floating 窗口在浮层内**不可最大化**（源码断言 "floating windows cannot be maximized or fullscreen"，`floating.rs:1375`）；该 action 对 floating 窗口的实际行为是**转平铺并最大化**（`workspace.set_maximized`，`workspace.rs:1325-1350`）。
- `consume-or-expel-window-*`：对 floating 显式 no-op（`workspace.rs:1101-1108`）。已有社区请求要求其改为移动 floating 窗口（discussion #3431，截至 25.11 未实现）。
- `switch-focus-between-floating-and-tiling`（默认 `Mod+Shift+V`）：在两种布局间切换焦点；`focus-column-*` 等聚焦类 binding 在 floating 焦点时作用于浮窗。
- 鼠标交互（替代键盘）：拖拽移动（`Mod+LeftMouse` 默认手势）、拖边缘缩放（interactive resize，`floating.rs:51` 起）、移动中右键切换 floating/tiling（25.01 起）。
- floating 布局不滚动、无列概念：`move-column-*` 对其无意义。

## 5. 默认绑定清单（resources/default-config.kdl，与浮窗相关）

| 按键 | 动作 | 说明 |
|---|---|---|
| `Mod+V` | `toggle-window-floating` | 浮窗/平铺切换 |
| `Mod+Shift+V` | `switch-focus-between-floating-and-tiling` | 焦点切换 |
| `Mod+Ctrl+J/K`、`Mod+Ctrl+Down/Up` | `move-window-down/up` | 垂直移动（floating 生效） |
| `Mod+Shift+Equal/Minus` | `set-window-height "+10%" / "-10%"` | 垂直缩放 |
| `Mod+Ctrl+Shift+R` | `switch-preset-window-height` | 预设高度循环 |
| `Mod+Ctrl+R` | `reset-window-height` | 仅平铺有效 |
| `Mod+M` | `maximize-window-to-edges` | floating 时转为平铺最大化 |

未绑默认键：`move-window-left/right`、`move-window-to-workspace-*` 系列（floating 随工作区走，每工作区有独立浮层）、`set-window-width`、`switch-preset-window-width`、`center-window`。

## 6. 版本与来源

- 功能引入：floating 布局自 **25.01**（year.month 版本制）起，同年 release notes 明示浮窗相关 binds 在焦点位于浮层时继续生效。
- 核验基点：niri main 分支源码（`src/layout/floating.rs`、`src/layout/workspace.rs`、`src/input/mod.rs`、`niri-config/src/binds.rs`、`niri-ipc/src/lib.rs`）、`resources/default-config.kdl`。
- 官方文档：wiki [Floating Windows](https://github.com/niri-wm/niri/wiki/Floating-Windows)（含 `move-floating-window` 示例）、[Configuration: Key Bindings](https://github.com/niri-wm/niri/wiki/Configuration:-Key-Bindings)。
- 社区线索：[discussion #3431](https://github.com/niri-wm/niri/discussions/3431)（consume-or-expel 移动浮窗的未实现请求）、[issue #2976](https://github.com/niri-wm/niri/issues/2976)（键盘移动浮窗相关讨论）。