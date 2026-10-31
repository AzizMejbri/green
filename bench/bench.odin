package main

import "core:fmt"
import "core:time"
import "core:sys/linux"
import "core:sys/linux/uring"
import green ".."

ITERS_SWITCH  :: 1_000_000
ITERS_YIELD   :: 200_000
ITERS_URING   :: 50_000
ITERS_CHAN    :: 200_000

report :: proc(name: string, iters: int, d: time.Duration) {
	ns := time.duration_nanoseconds(d)
	per_op := f64(ns) / f64(iters)
	fmt.printfln("%-32s %10d iters  %10.2f ns/op  %12d ns total", name, iters, per_op, ns)
}

// ---------------------------------------------------------------------------
// 1. Raw switch_ctx ping-pong -- below the fiber/scheduler layer entirely,
// isolates the hand-written asm primitive's own cost.

@(private = "file")
raw_main_ctx: green.Context
@(private = "file")
raw_fiber_ctx: green.Context
@(private = "file")
raw_count: int
@(private = "file")
raw_iters: int

// The fiber itself decides when to stop and calls ld_ctx on that exact
// iteration, instead of switch_ctx-ing back one last time and leaving
// main to notice the count and never resume it -- that would abandon the
// fiber mid-call, still "suspended" on a stack that's about to be freed
// when bench_raw_switch returns. Matching exit timing on both sides
// avoids ever having a fiber left dangling.
@(private = "file")
raw_switch_entry :: proc "c" () {
	for {
		raw_count += 1
		if raw_count >= raw_iters {
			green.ld_ctx(&raw_main_ctx)
		}
		green.switch_ctx(&raw_fiber_ctx, &raw_main_ctx)
	}
}

bench_raw_switch :: proc() {
	stack, ok := green.stack_alloc()
	assert(ok)
	defer green.stack_free(stack)

	raw_count = 0
	raw_iters = ITERS_SWITCH
	green.context_init(&raw_fiber_ctx, stack, rawptr(raw_switch_entry))

	start := time.tick_now()
	for raw_count < raw_iters {
		green.switch_ctx(&raw_main_ctx, &raw_fiber_ctx)
	}
	d := time.tick_diff(start, time.tick_now())

	// each loop iteration above is one round trip = 2 switch_ctx calls
	report("raw switch_ctx (one-way)", ITERS_SWITCH * 2, d)
}

// ---------------------------------------------------------------------------
// 2. Full scheduler round-robin via sched_yield -- two fibers, pure CPU,
// nothing submitted to the ring. Delta vs #1 is the scheduler's own
// overhead (ring_drain's non-blocking check, run-queue push/pop, etc).

@(private = "file")
yield_sched: ^green.Scheduler
@(private = "file")
yield_count: int
@(private = "file")
yield_target: int

@(private = "file")
yield_pingpong :: proc() {
	for yield_count < yield_target {
		yield_count += 1
		green.sched_yield(yield_sched)
	}
}

bench_sched_yield :: proc() {
	s: green.Scheduler
	green.sched_init(&s)
	defer green.sched_deinit(&s)
	yield_sched = &s
	yield_count = 0
	yield_target = ITERS_YIELD

	green.sched_spawn(&s, yield_pingpong)
	green.sched_spawn(&s, yield_pingpong)

	start := time.tick_now()
	green._run(&s)
	d := time.tick_diff(start, time.tick_now())

	report("sched_yield (full round trip)", yield_target * 2, d)
}

// ---------------------------------------------------------------------------
// 3. Bare ring submit+drain round trip for IORING_OP_NOP -- isolates the
// io_uring syscall cost with no scheduler/fiber involvement at all.

bench_ring_nop :: proc() {
	r: green.Ring
	err := green.ring_init(&r)
	assert(err == .NONE)
	defer green.ring_deinit(&r)

	build_nop :: proc(ring: ^uring.Ring, user_data: u64, ctx: rawptr) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
		return uring.nop(ring, user_data)
	}

	out: green.Completions
	defer delete(out)

	start := time.tick_now()
	for _ in 0 ..< ITERS_URING {
		_, serr := green.ring_submit(&r, green.Request{fiber = 1, params = green.Raw_Params{build = build_nop, ctx = nil}})
		assert(serr == .NONE)
		_, derr := green.ring_drain(&r, &out, 1)
		assert(derr == .NONE)
	}
	d := time.tick_diff(start, time.tick_now())

	report("ring_submit+drain (NOP)", ITERS_URING, d)
}

// ---------------------------------------------------------------------------
// 4. The same NOP round trip, but through sched_block -- isolates the
// scheduler's added cost (run-queue bookkeeping, blocked-map, wake path)
// on top of #3's bare ring cost.

@(private = "file")
block_sched: ^green.Scheduler
@(private = "file")
block_count: int
@(private = "file")
block_target: int

@(private = "file")
build_nop_blocking :: proc(ring: ^uring.Ring, user_data: u64, ctx: rawptr) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	return uring.nop(ring, user_data)
}

@(private = "file")
block_nop_fiber :: proc() {
	for block_count < block_target {
		block_count += 1
		green.sched_block(block_sched, green.Raw_Params{build = build_nop_blocking, ctx = nil})
	}
}

bench_sched_block_nop :: proc() {
	s: green.Scheduler
	green.sched_init(&s)
	defer green.sched_deinit(&s)
	block_sched = &s
	block_count = 0
	block_target = ITERS_URING

	green.sched_spawn(&s, block_nop_fiber)

	start := time.tick_now()
	green._run(&s)
	d := time.tick_diff(start, time.tick_now())

	report("sched_block (NOP, full path)", block_target, d)
}

// ---------------------------------------------------------------------------
// 5. Uncontended channel send+recv -- no fiber/scheduler, just the ring
// buffer + atomics.

bench_channel_uncontended :: proc() {
	c: green.Chan(int, 64)

	start := time.tick_now()
	for i in 0 ..< ITERS_CHAN {
		ok := green.chan_send_priv(&c, i)
		assert(ok)
		_, rok := green.chan_recv_priv(&c)
		assert(rok)
	}
	d := time.tick_diff(start, time.tick_now())

	report("chan_send+recv (uncontended)", ITERS_CHAN, d)
}

// ---------------------------------------------------------------------------
// 6. Contended channel ping-pong through a capacity-1 Chan -- every single
// exchange forces a real park+wake (switch_ctx) on one side. Isolates the
// Go-style blocking channel machinery's cost (waitq alloc/free, rb_push,
// switch_ctx) specifically.

@(private = "file")
chan_sched: ^green.Scheduler
@(private = "file")
chan_c: ^green.Chan(int, 1)
@(private = "file")
chan_target: int

@(private = "file")
chan_sender :: proc() {
	for i in 0 ..< chan_target {
		green.sched_chan_send(chan_sched, chan_c, i)
	}
}

@(private = "file")
chan_receiver :: proc() {
	for _ in 0 ..< chan_target {
		green.sched_chan_recv(chan_sched, chan_c)
	}
}

bench_channel_contended :: proc() {
	s: green.Scheduler
	green.sched_init(&s)
	defer green.sched_deinit(&s)
	chan_sched = &s

	c: green.Chan(int, 1)
	chan_c = &c
	chan_target = ITERS_CHAN

	green.sched_spawn(&s, chan_sender)
	green.sched_spawn(&s, chan_receiver)

	start := time.tick_now()
	green._run(&s)
	d := time.tick_diff(start, time.tick_now())

	report("sched_chan (contended, 1 slot)", chan_target, d)
}

main :: proc() {
	fmt.println("green runtime benchmarks\n")
	bench_raw_switch()
	bench_sched_yield()
	bench_ring_nop()
	bench_sched_block_nop()
	bench_channel_uncontended()
	bench_channel_contended()

}
