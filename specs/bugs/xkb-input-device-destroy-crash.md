# 启动即断连致全部按键失效 — 诊断与修复记录

- 日期：2026-08-18
- 影响：rill 启动后所有绑定键无响应；鼠标/光标正常（合成器侧行为）
- 状态：已修复并验证

## 现象

启动 rill（river -c rill 或 init 内 exec rill）后：

- 按任何绑定键（Super+q、XF86 音量键等）均无响应
- 鼠标光标可正常移动
- 更新 river 版本后问题依旧
- kwm（kewuaa/kwm）同样出现此问题；上游 rill（codeberg.org/lzj15/rill）正常

## 环境

- 主机有 10+ 个输入设备（键盘/鼠标/触摸板等），启动时集中上报
- river + 本仓库（rill-ed）构建二进制直接运行
- 上游 rill 解析不了本仓库的配置（Config 结构体字段不同，std.zon.parse
  遇未知字段报错）→ 上游实际以内置默认键位运行 → 因此「上游正常」只能
  证明默认键位可用，不能证明本仓库配置无问题

## 诊断过程（排除项）

1. **river 版本/协议全局**：三方 client 均用 `river_xkb_bindings_v1` 全局
   `get_xkb_binding(seat, keysym, modifiers)` + `enable()`；上游/fork 均按
   v1 绑定。Modifiers 位定义（shift=1, ctrl=4, mod1=8, mod3=32, mod4=64,
   mod5=128）在三份协议 XML 中逐位一致 → 排除协议层/线路格式。
2. **配置**：三份仓库配置 (key, 修饰键) 均无重复；keysym 均可解析
   （zig build test 通过）→ 排除配置重复绑定。
3. **kwim 进程**：spawn_at_startup 注释掉 kwim 后问题依旧 → 排除 kwim
   进程本身。
4. **绑定注册**：`setupKeybindings` 与上游逻辑等价 → 排除注册路径。

## 定位（决定性日志）

启动日志（stderr 重定向捕获）仅三行即终止：

```
zipp: config loaded, keybindings=59 spawn=0
zipp: window manager bound; xkb_bindings=true layer_shell=true
unknown object (4278190090), message input_device(o)
Window manager stopped (read): .INVAL
```

- 配置解析、全局绑定均正常，随后出现协议错误 `unknown object`，rill 的
  Wayland 连接被合成器判定非法并断开 → 进程退出 → 无窗口管理器 →
  **所有按键必然无响应**（鼠标能动是因为光标渲染在合成器侧）。

## 根因机制

`src/kwim_hotplug.zig` 三个监听器（`river_input_manager_v1` /
`river_libinput_config_v1` / `river_xkb_config_v1`）收到事件携带的
`new_id` 对象（river_input_device_v1 / libinput_device_v1 /
xkb_keyboard_v1）后**立即调用 `data.id.destroy()`**。

破坏性时序：

1. 合成器下发 `input_device` 事件，new_id = 某对象（如 0xff00000a）。
2. 客户端监听器执行 `destroy()`：立刻从本地对象表移除该 id，并向服务器
   排队销毁请求。
3. 服务器仍在该对象上排队发送初始化事件（type/name/done），且在处理
   销毁请求后可**复用该 id** 给下一个设备。
4. 客户端 dispatch 后续事件时按 id 查本地对象表失败 → libwayland 报
   `unknown object` → 协议错误 → 连接被断。

启动时 10+ 设备集中上报 → 高概率撞上此竞态 → rill 启动即死。
上游 rill 不绑定这三个接口（无 kwim 支持），无此对象，故不受影响。

## 修复

`src/kwim_hotplug.zig`：移除三处 `data.id.destroy()`。

对象保留至 rill 退出：未挂监听器的对象收到事件是按需 no-op（dispatcher
默认空处理），无协议风险；泄漏量级可忽略（每设备事件少数对象，设备数量
有界）。

## 验证

- `zig build` 通过；`zig build test` 通过。
- 用户机上确认：`setupKeybindings registered 67/67`，按键事件
  `xkb event pressed/released` 正常流动，`locked=false` `overview=false`，
  不再出现 `unknown object` / `Window manager stopped`；绑定键全部恢复。

## 后续（未在本轮处理）

- **kwm 的同类问题**：独立项目，机制不同（kwm 不销毁这些对象，其失效与
  协议版本/配置假设有关），不属本仓库范围。
- **潜在的启动竞态**：`manage()` 在 `focused_output_idx == null` 时提前
  return，会跳过 `.setup_bindings`（仅在所有输出被禁的启动窗口期受影响）。
  现有代码已能自愈（输出恢复后下一次 manage_start 会补注册），未修。