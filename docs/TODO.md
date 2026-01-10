# Architecture

[x] Utilize libproc to retrieve list of processes
[] build a map of procs with pid as the key and an pointer to an object as the value
[] build proc object
  
# Data Structures

```zig
ProcList [*]Proc
```

```zig

      .PID: $PID,
      .Name: "$NAME",
      }

```

# Notes

- Clay: in the future replace the manual
management of widgets with a template engine like clay
= Mailbox/Channels: Use some sort of back end processes to ensure either a fork handles all
updates with a mutex that blocks us reading while it writes. For mailbox we would just query
state every redraw, or maybe somehow just get deltas
