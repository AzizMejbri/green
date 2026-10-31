# green

A small cooperative green-thread runtime for Odin on Linux, built around
`io_uring`.

`green` runs many fibers on a single scheduler thread. Fibers yield explicitly,
block on channels, or submit `io_uring` requests and park until the completion
is drained.

## Features

- Cooperative fibers with private `mmap`-backed stacks and guard pages
- Hand-written x86-64 context switching (System V ABI)
- FIFO scheduler run queue with bounded fiber capacity
- `io_uring` reactor with typed requests for common operations
- `Raw_Params` escape hatch for arbitrary `io_uring` operations
- Blocking channels with parked senders and receivers
- Scheduler-aware timeouts through `Timeout_Params`
- Per-fiber Odin `context`, inherited from the spawning fiber

## Requirements

- Linux with `io_uring` support
- Odin compiler
- GNU `as` (or another compatible assembler)
- `just` for the convenience recipes

## Layout

```text
context.odin          context layout and initialization
context_switch.s      x86-64 register save/restore and switching
fiber.odin            fiber lifecycle and entry trampoline
stack.odin            mmap stacks with guard pages
scheduler.odin        run queue, blocking, wakeups, and scheduling loop
ring.odin             io_uring submission and completion handling
channel.odin          blocking channel implementation
green.odin            package-level runtime API
utils/ringbuffer.odin fixed-capacity run queue
bench/bench.odin      runtime microbenchmarks
```

## Quick start

```odin
package main

import green "green"

worker :: proc() {
    for _ in 0 ..< 10 {
        green.yield()
    }
}

main :: proc() {
    green.rt_init()
    defer green.rt_deinit()

    green.spawn(worker)
    green.run()
}
```

`green.run()` returns after every spawned fiber has finished. A fiber can call
`green.exit()` to terminate itself early.

### Spawning with arguments

Odin procs do not close over their environment, so `green.spawn` accepts a
single argument value that is copied into the fiber:

```odin
Args :: struct {
    count: int,
}

worker :: proc(args: Args) {
    for _ in 0 ..< args.count {
        green.yield()
    }
}

green.spawn(worker, Args{count = 5})
```

### Channels

```odin
ch: green.Chan(int, 16)

sender :: proc(ch: ^green.Chan(int, 16)) {
    for i in 0 ..< 10 {
        green.chan_send(ch, i)
    }
}

receiver :: proc(ch: ^green.Chan(int, 16)) {
    for _ in 0 ..< 10 {
        value := green.chan_recv(ch)
        _ = value
    }
}

green.spawn(sender, &ch)
green.spawn(receiver, &ch)
```

A full channel parks the sender. An empty channel parks the receiver. Both are
woken when the opposite side makes progress.

### io_uring requests

Submit an operation from a fiber with `green.request`; the fiber parks until
the matching completion is processed:

```odin
params: green.Request_Params = green.Timeout_Params{ns = 1_000_000}
result := green.request(&params)
```

Typed request parameters are available for read, write, timeout, accept, recv,
send, connect, and cancel. For other operations, use `Raw_Params` with an
explicit `uring` builder callback.

## Build and test

```bash
just check
just test
```

Without `just`:

```bash
as context_switch.s -o context_switch.o
odin check . -vet -no-entry-point
odin test . -vet
```

`context_switch.o` is generated from `context_switch.s` and is ignored by Git.

## Benchmarks

```bash
just bench
```

The benchmarks cover raw context switching, scheduler round trips, bare
`io_uring` submission, scheduler-blocking I/O, and both uncontended and
contended channel paths.

## Limit probing

`just stress` runs the fixed stress suite. To search for a boundary under a
controlled memory budget, build the standalone probe:

```bash
just limits
(ulimit -v 524288; ./build/limits fibers 100000)
(ulimit -v 524288; ./build/limits channels 25000)
(ulimit -v 524288; ./build/limits requests 42000 1000000000)
(ulimit -v 524288; ./build/limits ring 15000000)
./build/limits burst 64
```

The probe exits zero while the requested load succeeds and non-zero at the
first failure, so it can be driven from a shell binary search. `burst` measures
how many requests can be queued through `ring_submit` before the io_uring
submission queue fills; the scheduler path drains between submissions, so it is
not limited by that queue depth.

## Runtime model

- One scheduler thread owns the `io_uring` ring and all fibers.
- Fibers are cooperatively scheduled; there is no preemption.
- `sched_block` parks the current fiber and records its `io_uring` request.
- `ring_drain` converts completions into wakeups for parked fibers.
- Channel waits and run-queue operations are scheduler-local.
- The runtime is not designed for multiple scheduler threads or work stealing.

## Limits

- Linux x86-64 only
- `Rt_Config.max_fibers` defaults to 1024 as the initial run-queue capacity;
  the queue grows as needed
- `Rt_Config.max_requests` defaults to 4096 and is a hard cap on simultaneous
  in-flight io_uring operations
- `Rt_Config.default_stack_size` defaults to 8 KiB, plus a guard page

## License

MIT. See [LICENSE](LICENSE).
