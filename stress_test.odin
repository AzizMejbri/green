package green

import "core:container/queue"
import "core:sys/linux"
import "core:sys/linux/uring"
import "core:testing"

// Tunable stress sizes. The defaults are deliberately well past the old
// compile-time fiber cap and force the request pool to its configured limit.
STRESS_FIBER_COUNT      :: 10_000
STRESS_CHANNEL_PAIRS    :: 2_000
STRESS_CHANNEL_CAP      :: 64
STRESS_IO_REQUESTS      :: 64
STRESS_RING_REQUESTS    :: 16
STRESS_STACK_OVERRIDE   :: 12 * 1024
STRESS_INITIAL_FIBERS   :: 16

@(private = "file")
g_stress_sched: ^Scheduler

@(private = "file")
g_stress_counter: int

@(private = "file")
stress_yield_worker :: proc() {
	sched_yield(g_stress_sched)
	g_stress_counter += 1
}

@(private = "file")
g_stress_chan: ^Chan(int, STRESS_CHANNEL_CAP)

@(private = "file")
g_stress_received: int

@(private = "file")
stress_sender :: proc() {
	sched_chan_send(g_stress_sched, g_stress_chan, 1)
}

@(private = "file")
stress_receiver :: proc() {
	_ = sched_chan_recv(g_stress_sched, g_stress_chan)
	g_stress_received += 1
}

@(private = "file")
g_stress_pipes: [STRESS_IO_REQUESTS][2]linux.Fd

@(private = "file")
g_stress_pipe_open: [STRESS_IO_REQUESTS]bool

@(private = "file")
g_stress_io_bufs: [STRESS_IO_REQUESTS][1]u8

@(private = "file")
g_stress_io_results: [STRESS_IO_REQUESTS]i32

@(private = "file")
g_stress_free_at_cap: int

@(private = "file")
stress_reader :: proc(i: int) {
	g_stress_io_results[i] = sched_block(g_stress_sched, Read_Params{
		fd = g_stress_pipes[i][0],
		buf = g_stress_io_bufs[i][:],
		offset = 0,
	})
}

@(private = "file")
stress_writer :: proc() {
	// All readers run before this fiber and have already submitted their
	// reads, so the request pool should be completely exhausted here.
	g_stress_free_at_cap = int(g_stress_sched.ring.free_top)

	byte := [1]u8{'x'}
	for i in 0 ..< STRESS_IO_REQUESTS {
		n, err := linux.write(g_stress_pipes[i][1], byte[:])
		ensure(err == .NONE, "stress writer: pipe write failed")
		ensure(n == 1, "stress writer: short pipe write")
	}
}

@(private = "file")
g_stress_stack_cap: int

@(private = "file")
stress_stack_probe :: proc() {
	g_stress_stack_cap = int(g_stress_sched.current.stack.cap)
}

@(private = "file")
stress_build_nop :: proc(ring: ^uring.Ring, user_data: u64, ctx: rawptr) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	return uring.nop(ring, user_data)
}

// Proves max_requests is a real cap, not a sizing hint: exactly that many
// operations fit, the next one gets ENOMEM, and completed operations return
// their slots for reuse.
@(private = "file")
stress_ring_hard_cap :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r, STRESS_RING_REQUESTS)
	testing.expect_value(t, err, linux.Errno.NONE)
	if err != linux.Errno.NONE {return}
	defer ring_deinit(&r)

	for i in 0 ..< STRESS_RING_REQUESTS {
		_, serr := ring_submit(&r, Request{
			fiber = Fiber_Id(i + 1),
			params = Raw_Params{build = stress_build_nop, ctx = nil},
		})
		testing.expectf(t, serr == .NONE, "request %d/%d should fit, got %v", i + 1, STRESS_RING_REQUESTS, serr)
		if serr != .NONE {return}
	}

	_, serr := ring_submit(&r, Request{
		fiber = Fiber_Id(STRESS_RING_REQUESTS + 1),
		params = Raw_Params{build = stress_build_nop, ctx = nil},
	})
	testing.expect_value(t, serr, linux.Errno.ENOMEM)

	out: Completions
	defer delete(out)

	n, derr := ring_drain(&r, &out, u32(STRESS_RING_REQUESTS))
	testing.expect_value(t, derr, linux.Errno.NONE)
	testing.expect_value(t, n, u32(STRESS_RING_REQUESTS))
	testing.expect_value(t, len(out), STRESS_RING_REQUESTS)

	// The drained requests must have returned every slot to the free pool.
	_, reuse_err := ring_submit(&r, Request{
		fiber = Fiber_Id(999_999),
		params = Raw_Params{build = stress_build_nop, ctx = nil},
	})
	testing.expect_value(t, reuse_err, linux.Errno.NONE)
	_, derr = ring_drain(&r, &out, 1)
	testing.expect_value(t, derr, linux.Errno.NONE)
}

// Exercises the runtime's configurable limits together:
//
//   1. the run queue grows far past both its starting capacity and the old
//      1024-fiber compile-time cap;
//   2. channels handle thousands of parked senders and receivers;
//   3. max_requests is reached exactly by concurrent blocked I/O, then fully
//      released as the completions arrive;
//   4. the request pool rejects one operation past its configured limit and
//      reuses slots afterwards;
//   5. default_stack_size from Rt_Config reaches newly allocated stacks.
//
// Odin's test runner is multithreaded, while this runtime owns process-global
// scheduler state. Run this test with ODIN_TEST_THREADS=1; `just test` and
// `just stress` do that.
@(test)
test_runtime_limits_under_stress :: proc(t: ^testing.T) {
	s: Scheduler
	sched_init(&s, Rt_Config{
		max_fibers         = STRESS_INITIAL_FIBERS,
		max_requests       = STRESS_IO_REQUESTS,
		default_stack_size = 8 * 1024,
	})
	defer sched_deinit(&s)
	g_stress_sched = &s

	// 1. Run-queue growth.
	g_stress_counter = 0
	for _ in 0 ..< STRESS_FIBER_COUNT {
		sched_spawn(&s, stress_yield_worker)
	}

	testing.expect_value(t, queue.len(s.runq), STRESS_FIBER_COUNT)
	testing.expectf(
		t,
		queue.cap(s.runq) > STRESS_INITIAL_FIBERS,
		"run queue should grow past its initial capacity, got cap %d",
		queue.cap(s.runq),
	)

	_run(&s)
	testing.expect_value(t, g_stress_counter, STRESS_FIBER_COUNT)
	testing.expect_value(t, queue.len(s.runq), 0)
	testing.expect_value(t, s.alive, 0)

	// 2. Channel parking and wakeups under load.
	c: Chan(int, STRESS_CHANNEL_CAP)
	g_stress_chan = &c
	g_stress_received = 0

	for _ in 0 ..< STRESS_CHANNEL_PAIRS {
		sched_spawn(&s, stress_sender)
	}
	for _ in 0 ..< STRESS_CHANNEL_PAIRS {
		sched_spawn(&s, stress_receiver)
	}

	_run(&s)
	testing.expect_value(t, g_stress_received, STRESS_CHANNEL_PAIRS)
	testing.expect_value(t, s.alive, 0)

	// 3. Exhaust max_requests with real blocked I/O.
	for i in 0 ..< STRESS_IO_REQUESTS {
		fds: [2]linux.Fd
		perr := linux.pipe2(&fds, {})
		testing.expect_value(t, perr, linux.Errno.NONE)
		if perr != .NONE {return}

		g_stress_pipes[i] = fds
		g_stress_pipe_open[i] = true
		g_stress_io_results[i] = -999
	}
	defer {
		for i in 0 ..< STRESS_IO_REQUESTS {
			if g_stress_pipe_open[i] {
				linux.close(g_stress_pipes[i][0])
				linux.close(g_stress_pipes[i][1])
				g_stress_pipe_open[i] = false
			}
		}
	}

	g_stress_free_at_cap = -1
	for i in 0 ..< STRESS_IO_REQUESTS {
		sched_spawn(&s, stress_reader, i)
	}
	sched_spawn(&s, stress_writer)

	_run(&s)

	testing.expect_value(t, g_stress_free_at_cap, 0)
	testing.expect_value(t, s.ring.free_top, u32(STRESS_IO_REQUESTS))
	for i in 0 ..< STRESS_IO_REQUESTS {
		testing.expect_value(t, g_stress_io_results[i], i32(1))
	}
	testing.expect_value(t, s.alive, 0)

	// 4. Ring-level hard cap and slot reuse.
	stress_ring_hard_cap(t)

	// 5. Rt_Config.default_stack_size is applied to new fibers.
	s2: Scheduler
	sched_init(&s2, Rt_Config{
		max_fibers         = 4,
		max_requests       = 4,
		default_stack_size = STRESS_STACK_OVERRIDE,
	})
	defer sched_deinit(&s2)
	g_stress_sched = &s2

	g_stress_stack_cap = 0
	sched_spawn(&s2, stress_stack_probe)
	_run(&s2)

	testing.expect_value(t, g_stress_stack_cap, int(STRESS_STACK_OVERRIDE))
	testing.expect_value(t, s2.alive, 0)
}
