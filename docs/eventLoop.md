# Event loop

## Libxev

Utilized for integration with kqueue as well as

### Example

```zig
  API Example:
  const xev = @import("xev");

  pub fn main() !void {
      var loop = try xev.Loop.init(.{});
      defer loop.deinit();

      // Watch for process events via kqueue (on macOS)
      var proc_watcher = try xev.Async.init();
      proc_watcher.wait(&loop, .{}, struct {
          fn callback(userdata: ?*anyopaque, result: xev.Result) void {
              // Process event received - send to channel
              channel.send(.{ .exited = pid });
          }
      }.callback);

      // Timer for periodic reconciliation
      var timer = try xev.Timer.init();
      timer.set(&loop, 2000, struct {
          fn callback(userdata: ?*anyopaque, result: xev.Result) void {
              reconcileProcessList();
          }
      }.callback);

      // Run event loop (blocks)
      try loop.run(.until_done);
  }
```
