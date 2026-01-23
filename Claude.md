# Blade - Terminal Process Viewer (macOS)

NOTICE: CRITICAL: do NOT edit code files, instead build college level lessons around the proposed changes so the user can follow along and implement manually

## Data Flow

Producer thread -> SPSC queue (Batch with ArenaAllocator) -> Main thread polls -> AppState.recieveBatch() -> rebuildView() filters by search -> render()

## Dependencies

- zigtui: TUI framework
- spsc_queue: Lock-free queue
- libproc: macOS process API (linked via build.zig)
