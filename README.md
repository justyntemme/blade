# Blade

A terminal-based process viewer for macOS, built with Zig. Blade displays running processes in a tree hierarchy with live CPU and memory stats, vim-style navigation, search filtering, and per-process detail inspection.

## Requirements

- macOS
- Zig 0.15.2 or later
- A terminal with kitty keyboard protocol support is recommended (Kitty, WezTerm, Ghostty, iTerm2) for full keybinding support including Shift+Enter

## Building

```
zig build
```

The binary is placed in `zig-out/bin/Blade`.

## Running

```
zig build run
```

Or run the binary directly:

```
./zig-out/bin/Blade
```

## Keybindings

Press `?` at any time to open the in-app help overlay.

### Navigation

| Key       | Action    |
|-----------|-----------|
| `j` / `Down` | Move down |
| `k` / `Up`   | Move up   |
| `u`       | Page up   |
| `d`       | Page down |
| `g`       | Jump to top |
| `G`       | Jump to bottom |

### Process Tree

| Key              | Action              |
|------------------|---------------------|
| `Tab` / `Shift+Enter` / `Space` | Toggle expand/collapse |
| `*`              | Expand/collapse all |

### Process Actions

| Key     | Action         |
|---------|----------------|
| `Enter` | Open detail view |
| `x`     | Kill process (SIGTERM) |
| `X`     | Force kill process (SIGKILL) |

### Search

| Key   | Action        |
|-------|---------------|
| `/`   | Start search  |
| `c`   | Clear search  |
| `Esc` | Exit search   |

Search is live -- results filter as you type. Press `Enter` to confirm the search and return to navigation mode.

### Sorting

| Key | Action       |
|-----|--------------|
| `P` | Sort by PID  |
| `N` | Sort by name |
| `C` | Sort by CPU  |
| `M` | Sort by memory |

### Detail View

| Key   | Action            |
|-------|-------------------|
| `h`   | Focus left pane   |
| `l`   | Focus right pane  |
| `j/k` | Scroll focused pane |
| `q` / `Esc` | Close detail view |

### General

| Key         | Action    |
|-------------|-----------|
| `?`         | Toggle help |
| `q` / `Esc` | Quit      |

## License

See [LICENSE](LICENSE) for details.
