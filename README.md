# Blade

A terminal process viewer for macOS with vim-style navigation, tree display, live search, and per-process detail inspection. Built with Zig.

## Dependencies

- [zigtui](https://github.com/justyntemme/zigtui) -- terminal UI rendering and input handling
- [spsc-queue](https://github.com/freref/spsc-queue) -- lock-free queue for background process polling

Requires Zig 0.15.2+ and macOS.

## Build & Run

```
zig build run
```

## Keybindings

Press `?` in-app for the full help overlay.

| Key | Action |
|-----|--------|
| `j/k`, `Up/Down` | Navigate |
| `u/d` | Page up/down |
| `g/G` | Jump to top/bottom |
| `Tab`, `Shift+Enter`, `Space` | Toggle expand |
| `*` | Expand/collapse all |
| `Enter` | Open detail view |
| `h/l` | Focus left/right pane (detail view) |
| `/` | Search |
| `c` | Clear search |
| `P/N/C/M` | Sort by PID/Name/CPU/Mem |
| `x/X` | Kill / Force kill |
| `q`, `Esc` | Quit / Back |

## Documentation

See [docs/](docs/) for architecture and design details.
