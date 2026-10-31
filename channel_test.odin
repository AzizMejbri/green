package green

import "core:testing"

@(test)
test_channel_send_recv_fifo :: proc(t: ^testing.T) {
	c: Chan(int, 4)

	_, ok := chan_recv_priv(&c)
	testing.expect(t, !ok, "recv on empty channel should fail")

	testing.expect(t, chan_send_priv(&c, 1))
	testing.expect(t, chan_send_priv(&c, 2))
	testing.expect(t, chan_send_priv(&c, 3))

	v, vok := chan_recv_priv(&c)
	testing.expect(t, vok)
	testing.expect_value(t, v, 1)

	v, vok = chan_recv_priv(&c)
	testing.expect(t, vok)
	testing.expect_value(t, v, 2)

	v, vok = chan_recv_priv(&c)
	testing.expect(t, vok)
	testing.expect_value(t, v, 3)

	_, vok = chan_recv_priv(&c)
	testing.expect(t, !vok, "recv after draining should fail")
}

@(test)
test_channel_send_fails_when_full :: proc(t: ^testing.T) {
	c: Chan(int, 4)

	testing.expect(t, chan_send_priv(&c, 1))
	testing.expect(t, chan_send_priv(&c, 2))
	testing.expect(t, chan_send_priv(&c, 3))
	testing.expect(t, chan_send_priv(&c, 4))

	testing.expect(t, !chan_send_priv(&c, 5), "send on a full channel should fail")

	v, ok := chan_recv_priv(&c)
	testing.expect(t, ok)
	testing.expect_value(t, v, 1)

	// freeing one slot should make room for exactly one more send
	testing.expect(t, chan_send_priv(&c, 5))
	testing.expect(t, !chan_send_priv(&c, 6), "channel should be full again")
}

// Fiber bodies are plain proc() (no params), so each blocking-channel
// test talks to its fibers via dedicated, uniquely named globals, same
// pattern as scheduler_test.odin.

@(private = "file")
g_rbs_sched: ^Scheduler
@(private = "file")
g_rbs_chan: ^Chan(int, 2)
@(private = "file")
g_rbs_result: int

@(private = "file")
rbs_receiver :: proc() {
	g_rbs_result = sched_chan_recv(g_rbs_sched, g_rbs_chan)
}

@(private = "file")
rbs_sender :: proc() {
	sched_chan_send(g_rbs_sched, g_rbs_chan, 42)
}

// Receiver is spawned (and so runs) first, on an empty channel -- it must
// actually park on c.recvq and suspend via switch_ctx, not spin. The
// sender runs second, and its chan_send must wake the parked receiver
// rather than the receiver ever re-polling on its own.
@(test)
test_sched_chan_recv_blocks_until_send :: proc(t: ^testing.T) {
	g_rbs_result = -999
	c: Chan(int, 2)
	g_rbs_chan = &c

	s: Scheduler
	sched_init(&s)
	defer sched_deinit(&s)
	g_rbs_sched = &s

	sched_spawn(&s, rbs_receiver)
	sched_spawn(&s, rbs_sender)
	_run(&s)

	testing.expect_value(t, g_rbs_result, 42)
}

@(private = "file")
g_sbr_sched: ^Scheduler
@(private = "file")
g_sbr_chan: ^Chan(int, 1)
@(private = "file")
g_sbr_recv_result: int
@(private = "file")
g_sbr_send_done: bool

@(private = "file")
sbr_sender :: proc() {
	sched_chan_send(g_sbr_sched, g_sbr_chan, 99) // channel starts full -- must block
	g_sbr_send_done = true
}

@(private = "file")
sbr_receiver :: proc() {
	g_sbr_recv_result = sched_chan_recv(g_sbr_sched, g_sbr_chan)
}

// Symmetric case: the channel starts pre-filled to capacity, so the
// sender (spawned, and so run, first) must park on c.sendq immediately.
// The receiver draining the pre-filled value must wake the blocked
// sender, which then successfully delivers its own value on retry.
@(test)
test_sched_chan_send_blocks_until_recv :: proc(t: ^testing.T) {
	g_sbr_recv_result = -999
	g_sbr_send_done = false

	c: Chan(int, 1)
	testing.expect(t, chan_send_priv(&c, -1)) // pre-fill to capacity
	g_sbr_chan = &c

	s: Scheduler
	sched_init(&s)
	defer sched_deinit(&s)
	g_sbr_sched = &s

	sched_spawn(&s, sbr_sender)
	sched_spawn(&s, sbr_receiver)
	_run(&s)

	testing.expect_value(t, g_sbr_recv_result, -1)
	testing.expect(t, g_sbr_send_done, "blocked sender should have been woken and completed")
}
