package main

// limits is a small standalone probe used to find where the runtime stops
// succeeding under a controlled resource budget. It deliberately exits
// non-zero (or aborts, when the runtime's own ensure fires) at the first
// failure so a shell loop can binary-search the boundary.
//
// Usage:
//   limits fibers <count>
//   limits channels <pairs>
//   limits requests <count> [timeout_ns]
//   limits ring <max_requests>
//   limits burst <max_requests>

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:sys/linux/uring"
import green ".."

DEFAULT_TIMEOUT_NS :: uint(1_000_000_000)

g_sched: ^green.Scheduler

g_fiber_count: int
fiber_worker :: proc() {
	green.sched_yield(g_sched)
	g_fiber_count += 1
}

g_chan: ^green.Chan(int, 64)
g_received: int
chan_sender :: proc() {
	green.sched_chan_send(g_sched, g_chan, 1)
}
chan_receiver :: proc() {
	_ = green.sched_chan_recv(g_sched, g_chan)
	g_received += 1
}

g_timeout_ns: uint
g_free_at_cap: int
request_worker :: proc() {
	_ = green.sched_block(g_sched, green.Timeout_Params{ns = g_timeout_ns})
}
request_probe :: proc() {
	g_free_at_cap = int(g_sched.ring.free_top)
}

build_nop :: proc(ring: ^uring.Ring, user_data: u64, ctx: rawptr) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
	return uring.nop(ring, user_data)
}

usage :: proc() {
	fmt.eprintln("usage:")
	fmt.eprintln("  limits fibers <count>")
	fmt.eprintln("  limits channels <pairs>")
	fmt.eprintln("  limits requests <count> [timeout_ns]")
	fmt.eprintln("  limits ring <max_requests>")
	fmt.eprintln("  limits burst <max_requests>")
	os.exit(2)
}

parse_arg :: proc(args: []string, index: int) -> int {
	value, ok := strconv.parse_int(args[index])
	if !ok || value < 0 {
		fmt.eprintfln("invalid count: %q", args[index])
		os.exit(2)
	}
	return value
}

run_fibers :: proc(n: int) {
	s: green.Scheduler
	green.sched_init(&s, green.Rt_Config{
		max_fibers         = 16,
		max_requests       = 16,
		default_stack_size = 8 * 1024,
	})
	defer green.sched_deinit(&s)
	g_sched = &s

	g_fiber_count = 0
	for _ in 0 ..< n {
		green.sched_spawn(&s, fiber_worker)
	}
	green._run(&s)

	if g_fiber_count != n {
		fmt.eprintfln("fibers: expected %d completions, got %d", n, g_fiber_count)
		os.exit(1)
	}
	fmt.printfln("fibers ok: %d", n)
}

run_channels :: proc(pairs: int) {
	s: green.Scheduler
	green.sched_init(&s, green.Rt_Config{
		max_fibers         = 16,
		max_requests       = 16,
		default_stack_size = 8 * 1024,
	})
	defer green.sched_deinit(&s)
	g_sched = &s

	c: green.Chan(int, 64)
	g_chan = &c
	g_received = 0

	for _ in 0 ..< pairs {
		green.sched_spawn(&s, chan_sender)
	}
	for _ in 0 ..< pairs {
		green.sched_spawn(&s, chan_receiver)
	}
	green._run(&s)

	if g_received != pairs {
		fmt.eprintfln("channels: expected %d receives, got %d", pairs, g_received)
		os.exit(1)
	}
	fmt.printfln("channels ok: %d pairs", pairs)
}

run_requests :: proc(n: int, timeout_ns: uint) {
	if n <= 0 || n > int(max(u32)) {
		fmt.eprintfln("requests: count out of range: %d", n)
		os.exit(2)
	}

	s: green.Scheduler
	green.sched_init(&s, green.Rt_Config{
		max_fibers         = 16,
		max_requests       = u32(n),
		default_stack_size = 8 * 1024,
	})
	defer green.sched_deinit(&s)
	g_sched = &s
	g_timeout_ns = timeout_ns
	g_free_at_cap = -1

	for _ in 0 ..< n {
		green.sched_spawn(&s, request_worker)
	}
	green.sched_spawn(&s, request_probe)
	green._run(&s)

	if g_free_at_cap != 0 {
		fmt.eprintfln("requests: cap was not reached before completion (free_top=%d)", g_free_at_cap)
		os.exit(1)
	}
	if s.ring.free_top != u32(n) {
		fmt.eprintfln("requests: slots not fully released (free_top=%d, expected %d)", s.ring.free_top, n)
		os.exit(1)
	}
	fmt.printfln("requests ok: %d in flight", n)
}

run_ring :: proc(n: int) {
	if n <= 0 || n > int(max(u32)) {
		fmt.eprintfln("ring: count out of range: %d", n)
		os.exit(2)
	}

	r: green.Ring
	err := green.ring_init(&r, u32(n))
	if err != .NONE {
		fmt.eprintfln("ring: init failed: %v", err)
		os.exit(1)
	}
	defer green.ring_deinit(&r)

	if r.free_top != u32(n) {
		fmt.eprintfln("ring: free_top=%d, expected %d", r.free_top, n)
		os.exit(1)
	}
	fmt.printfln("ring ok: %d request slots", n)
}

run_burst :: proc(max_requests: int) {
	if max_requests <= 0 || max_requests > int(max(u32)) {
		fmt.eprintfln("burst: count out of range: %d", max_requests)
		os.exit(2)
	}

	r: green.Ring
	err := green.ring_init(&r, u32(max_requests))
	if err != .NONE {
		fmt.eprintfln("burst: init failed: %v", err)
		os.exit(1)
	}
	defer green.ring_deinit(&r)

	for i in 0 ..< max_requests {
		_, serr := green.ring_submit(&r, green.Request{
			fiber = green.Fiber_Id(i + 1),
			params = green.Raw_Params{build = build_nop, ctx = nil},
		})
		if serr != .NONE {
			fmt.printfln("burst stopped at %d/%d: %v", i, max_requests, serr)
			os.exit(1)
		}
	}
	fmt.printfln("burst ok: %d queued", max_requests)
}

main :: proc() {
	args := os.args
	if len(args) < 3 {usage()}

	mode := args[1]
	n := parse_arg(args, 2)

	switch mode {
	case "fibers":
		run_fibers(n)
	case "channels":
		run_channels(n)
	case "requests":
		timeout_ns := DEFAULT_TIMEOUT_NS
		if len(args) >= 4 {
			timeout_ns = uint(parse_arg(args, 3))
		}
		run_requests(n, timeout_ns)
	case "ring":
		run_ring(n)
	case "burst":
		run_burst(n)
	case:
		usage()
	}
}
