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
  - We also could use events to send which pid got
  updated. the Chanel could have a union enum for event type and the pid the event is baed on
  EVENTADD
  EVENTCLOSE
  EVENTUPDATE
  eventSnapshot -- full refresh
Category E: libxev
Category D:   2.3 freref/spsc-queue - simple high performance
  Repository: github.com/freref/spsc-queue
  Approach: Wait-free, cache-line optimized ring buffer
  Variants: Flexible capacity or power-of-2 enforced (faster)
Category C: mailbox
  github.com/Edartruwu/zig-routines - big platform has kqueue integration
  github.com/g41797/mailbox - very simple small footprint.
Category B: Go channels
Category A: Lock-Free Queues - complex high preformance

  2.2 bchan (High-Performance MPSC)

  Repository: github.com/boonzy00/bchan

 option 2: Use libxev for the data thread's event loop, pair with SPSC queue for cross-thread communication.
