# Rill Ed
A minimalist scrolling window manager for [river](https://isaacfreund.com/software/river/),

> **Note:** This project is an improved fork of the original [rill](https://codeberg.org/lzj15/rill) by [lzj15](https://codeberg.org/lzj15). It builds on top of the original work with enhancements and fixes.

fork of [rill](https://codeberg.org/lzj15/rill), implementing the [river-window-management-v1](https://isaacfreund.com/docs/wayland/river-window-management-v1/) protocol. Inspired by [kwm](https://github.com/kewuaa/kwm).

## Features
* Per-workspace layout (scrolling or floating)
* Floating windows center on screen; drag with mouse to reposition
* Workspaces (10 per output)
* Smooth animations (configurable duration, zero to disable)
* Live-reloading config
* Multi-output with window migration
* TTY switch resilience — preserves windows and focus when switching VTs
* Config preprocessing (`// @if(hostname=...)`, `// @include(file)` — directives pass through as ZON comments)

<video src="https://pub-da8894d425e3482384b5adec2dcc2361.r2.dev/recording.mp4" controls> </video>

## Installation
You can download pre-built binary from [releases](https://codeberg.org/lzj15/rill/releases).

## Configuration
Rill searches for a config file at the following locations in order:  
`$XDG_CONFIG_HOME/rill/config.zon`  
`$HOME/.config/rill/config.zon`  
See the [default config](https://codeberg.org/lzj15/rill/src/branch/main/config.zon) as an example.

## Usage
[River](https://isaacfreund.com/software/river/) needs to be installed first.  
Run `rill` in [river's init file](https://codeberg.org/river/river#usage), or directly run `river -c rill`.

### Default Keybindings
| Keybinding | Action |
|----------|--------|
| `Super` `q` | Close window |
| `Super` `f` | Toggle fullscreen |
| `Super` `minus` | Decrease window's width by a proportion of 0.1 |
| `Super` `equal` | Increase window's width by a proportion of 0.1 |
| `Super` `BackSpace` | Set window's width to a proportion of 0.5 |
| `Super` `Left` | Focus on window left |
| `Super` `Right` | Focus on window right |
| `Super` `Shift` `Left` | Move window to the left |
| `Super` `Shift` `Right` | Move window to the right |
| `Super` `v` | Toggle workspace floating |
| `Super` `Up` | Focus on workspace above |
| `Super` `Down` | Focus on workspace below |
| `Super` `grave` | Focus on previous workspace |
| `Super` `1~0` | Focus on workspace 1~10 |
| `Super` `Shift` `Up` | Move window to workspace above |
| `Super` `Shift` `Down` | Move window to workspace below |
| `Super` `Shift` `1~0` | Move window to workspace 1~10 |
| `Super` `h` | Focus on output left |
| `Super` `l` | Focus on output right |
| `Super` `k` | Focus on output above |
| `Super` `j` | Focus on output below |
| `Super` `Shift` `h` | Move window to output left |
| `Super` `Shift` `l` | Move window to output right |
| `Super` `Shift` `k` | Move window to output above |
| `Super` `Shift` `j` | Move window to output below |
| `Super` `Escape` | Exit river |
| `Super` `r` | Reload config |
| `Super` `t` | Open alacritty |
| `XF86AudioRaiseVolume` | Raise volume of PipeWire default audio sink by 5% |
| `XF86AudioLowerVolume` | Lower volume of PipeWire default audio sink by 5% |
| `XF86AudioMute` | Toggle mute for PipeWire default audio sink |
| `XF86AudioMicMute` | Toggle mute for PipeWire default audio source |

### Default Pointer Bindings
| Pointer Binding | Action |
|----------|--------|
| `Super` `Left Click` | Move floating window |
| `Super` `Right Click` | Resize floating window |

### Spawning external programs
Programs started via `.spawn` keybindings or `spawn_at_startup` are launched
in a new session and process group (`setsid` + double-fork). This detaches
them from rill's controlling terminal and ensures GUI programs such as
browsers, menus (e.g. wmenu), and sandbox wrappers (e.g. firejail) behave
the same as they do under other window managers.

## Build
### Dependencies
* zig 0.16
* wayland
* wayland-protocols
* xkbcommon
```sh
zig build --release=safe
```

### Source Layout
```
src/
  main.zig            event loop, manage cycle
  types.zig           WindowManager, Output, Workspace, Config
  actions.zig         KeybindingAction, PointerAction
  config.zig          ZON config loader, reload, preprocessing
  layout.zig          layout coordinator
  layout/
    scroller.zig      scrolling column layout
    floating.zig      floating window layout
    common.zig        shared rectangle helpers
  window.zig          window lifecycle
  output.zig          output management
  seat.zig            seat, pointer bindings
  keybinding.zig      keyboard binding setup and dispatch
  animation.zig       frame interpolation
  spawn.zig           process spawning
```
