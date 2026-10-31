package green

import "core:sys/linux"
import "core:container/queue"
import "core:testing"

// Fiber entry points are plain proc(), real Odin ABI, same as anywhere
// else -- fiber_trampoline (fiber.odin) bridges the gap to the raw asm
// ret-trampoline, so no "c" tag or manual context setup is needed here.
// Odin procs still don't close over their enclosing scope though, so
// each test's fiber bodies talk to their test via dedicated, uniquely
// named package-level globals rather than captured locals.

@(private = "file")
g_yield_trace: [dynamic]int
@(private = "file")
g_yield_sched: ^Scheduler

@(private = "file")
yield_fiber_a :: proc() {
  append(&g_yield_trace, 1)
  sched_yield(g_yield_sched)
  append(&g_yield_trace, 1)
  sched_yield(g_yield_sched)
  append(&g_yield_trace, 1)
  // falls off the end -- fiber_trampoline calls sched_kill automatically
}

@(private = "file")
yield_fiber_b :: proc() {
  append(&g_yield_trace, 2)
  sched_yield(g_yield_sched)
  append(&g_yield_trace, 2)
  sched_yield(g_yield_sched)
  append(&g_yield_trace, 2)
}

// Two pure-CPU fibers that only ever yield to each other -- nothing is
// ever submitted to the ring. Proves schedule()'s non-blocking-first
// drain doesn't deadlock when there's no I/O in flight, that switch_ctx
// actually round-robins between two real separate stacks in FIFO order,
// and that falling off the end of a plain proc() fiber body exits
// cleanly via the trampoline's automatic sched_kill.
@(test)
test_scheduler_yield_round_trip :: proc(t: ^testing.T) {
  clear(&g_yield_trace)
  defer delete(g_yield_trace)

  s: Scheduler
  sched_init(&s)
  defer sched_deinit(&s)
  g_yield_sched = &s

  sched_spawn(&s, yield_fiber_a)
  sched_spawn(&s, yield_fiber_b)
  _run(&s)

  expected := []int{1, 2, 1, 2, 1, 2}
  testing.expect_value(t, len(g_yield_trace), len(expected))
  for i in 0 ..< min(len(g_yield_trace), len(expected)) {
    testing.expect_value(t, g_yield_trace[i], expected[i])
  }

  testing.expect(t, queue.len(s.runq) == 0)
  testing.expect_value(t, len(s.blocked), 0)
}

@(private = "file")
g_block_sched: ^Scheduler
@(private = "file")
g_block_result: i32

@(private = "file")
block_timeout_fiber :: proc() {
  g_block_result = sched_block(g_block_sched, Timeout_Params{ns = 1_000_000}) // 1ms
}

// A fiber that actually suspends via sched_block on a real io_uring op
// (a timeout), with nothing else runnable in the meantime -- proves the
// full submit -> idle in ring_drain(wait_nr=1) -> wake_blocked ->
// resume-with-result path works end to end, not just the pure-CPU path.
@(test)
test_scheduler_block_timeout :: proc(t: ^testing.T) {
  g_block_result = -999

  s: Scheduler
  sched_init(&s)
  defer sched_deinit(&s)
  g_block_sched = &s

  sched_spawn(&s, block_timeout_fiber)
  _run(&s)

  // A bare IORING_OP_TIMEOUT firing on schedule completes with -ETIME --
  // that's success for a plain sleep, not a failure (same as ring_test.odin).
  testing.expect_value(t, g_block_result, -i32(linux.Errno.ETIME))
  testing.expect(t, queue.len(s.runq) == 0)
  testing.expect_value(t, len(s.blocked), 0)
}

@(private = "file")
g_pipe_sched: ^Scheduler
@(private = "file")
g_pipe_read_fd: linux.Fd
@(private = "file")
g_pipe_result: i32
@(private = "file")
g_pipe_buf: [16]u8

@(private = "file")
pipe_read_fiber :: proc() {
  g_pipe_result = sched_block(g_pipe_sched, Read_Params{fd = g_pipe_read_fd, buf = g_pipe_buf[:], offset = 0})
}

// Same round trip as above, but with a real external event (another fd
// becoming readable) rather than a self-contained timeout -- proves
// sched_block correctly carries back a real byte count, not just an
// error code.
@(test)
test_scheduler_block_pipe_read :: proc(t: ^testing.T) {
  g_pipe_result = -999

  fds: [2]linux.Fd
  perr := linux.pipe2(&fds, {})
  testing.expect_value(t, perr, linux.Errno.NONE)
  defer linux.close(fds[0])
  defer linux.close(fds[1])
  g_pipe_read_fd = fds[0]

  s: Scheduler
  sched_init(&s)
  defer sched_deinit(&s)
  g_pipe_sched = &s

  sched_spawn(&s, pipe_read_fiber)

  msg := transmute([]u8)string("hi")
  wn, werr := linux.write(fds[1], msg)
  testing.expect_value(t, werr, linux.Errno.NONE)
  testing.expect_value(t, wn, 2)

  _run(&s)

  testing.expect_value(t, g_pipe_result, i32(2))
  testing.expect_value(t, string(g_pipe_buf[:g_pipe_result]), "hi")
  testing.expect(t, queue.len(s.runq) == 0)
  testing.expect_value(t, len(s.blocked), 0)
}

@(private = "file")
g_ctx_sched: ^Scheduler
@(private = "file")
g_ctx_seen_at_entry: int
@(private = "file")
g_ctx_seen_after_yield: int

@(private = "file")
ctx_fiber :: proc() {
  g_ctx_seen_at_entry = context.user_index // inherited from the spawner, not a fresh default
  context.user_index = 777 // a fiber can freely change its own context
  sched_yield(g_ctx_sched)
  // resumes here after a real switch-away-and-back -- the mutation above
  // must have survived on its own, with no explicit save/restore step.
  g_ctx_seen_after_yield = context.user_index
}

// Proves a fiber inherits whatever context was active at its spawn()
// call site (not runtime.default_context()), that it can mutate its own
// context, that the mutation persists across a real suspend/resume via
// switch_ctx with no extra plumbing, and that none of this leaks back
// into the spawner's own context.
@(test)
test_scheduler_fiber_inherits_and_persists_context :: proc(t: ^testing.T) {
  g_ctx_seen_at_entry = -1
  g_ctx_seen_after_yield = -1

  s: Scheduler
  sched_init(&s)
  defer sched_deinit(&s)
  g_ctx_sched = &s

  context.user_index = 123
  sched_spawn(&s, ctx_fiber)
  _run(&s)

  testing.expect_value(t, g_ctx_seen_at_entry, 123)
  testing.expect_value(t, g_ctx_seen_after_yield, 777)
  testing.expect_value(t, context.user_index, 123) // the spawner's own context is untouched
}
