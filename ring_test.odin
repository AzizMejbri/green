package green

import "core:sys/linux"
import "core:sys/linux/uring"
import "core:testing"

@(test)
test_pack_unpack_user_data :: proc(t: ^testing.T) {
	cases := [][2]u32{{0, 0}, {1, 0}, {4095, 7}, {0, 0xffff_ffff}, {4095, 0xffff_ffff}}
	for c in cases {
		ud := pack_user_data(c[0], c[1])
		index, gen := unpack_user_data(ud)
		testing.expect_value(t, index, c[0])
		testing.expect_value(t, gen, c[1])
	}
}

@(test)
test_ring_init_deinit :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	testing.expect_value(t, r.free_top, u32(RT_DEFAULT_CONFIG.max_requests))
	ring_deinit(&r)
}

@(test)
test_ring_submit_exhausted :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	// Force the slab empty without actually submitting MAX_REQUESTS real ops.
	r.free_top = 0

	buf: [8]u8
	_, serr := ring_submit(&r, Request{fiber = 1, params = Read_Params{fd = 0, buf = buf[:], offset = 0}})
	testing.expect_value(t, serr, linux.Errno.ENOMEM)
}

@(test)
test_ring_submit_read_drain :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	fds: [2]linux.Fd
	perr := linux.pipe2(&fds, {})
	testing.expect_value(t, perr, linux.Errno.NONE)
	defer linux.close(fds[0])
	defer linux.close(fds[1])

	buf: [16]u8
	_, serr := ring_submit(&r, Request{fiber = 42, params = Read_Params{fd = fds[0], buf = buf[:], offset = 0}})
	testing.expect_value(t, serr, linux.Errno.NONE)

	msg := transmute([]u8)string("hi")
	wn, werr := linux.write(fds[1], msg)
	testing.expect_value(t, werr, linux.Errno.NONE)
	testing.expect_value(t, wn, 2)

	out: Completions
	defer delete(out)
	cn, derr := ring_drain(&r, &out, 1)
	testing.expect_value(t, derr, linux.Errno.NONE)
	testing.expect_value(t, cn, u32(1))
	result, ok := out[42]
	testing.expect(t, ok, "fiber 42 should have a completion")
	testing.expect_value(t, result, i32(2))
}

@(test)
test_ring_submit_timeout_drain :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	_, serr := ring_submit(&r, Request{fiber = 7, params = Timeout_Params{ns = 1_000_000}}) // 1ms
	testing.expect_value(t, serr, linux.Errno.NONE)

	out: Completions
	defer delete(out)
	cn, derr := ring_drain(&r, &out, 1)
	testing.expect_value(t, derr, linux.Errno.NONE)
	testing.expect_value(t, cn, u32(1))
	result, ok := out[7]
	testing.expect(t, ok, "fiber 7 should have a completion")
	// A bare IORING_OP_TIMEOUT firing on schedule completes with -ETIME —
	// that is success for a plain sleep, not a failure.
	testing.expect_value(t, result, -i32(linux.Errno.ETIME))
}

@(test)
test_resolve_cqe_stale_generation_dropped :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	buf: [8]u8
	id, serr := ring_submit(&r, Request{fiber = 3, params = Read_Params{fd = 0, buf = buf[:], offset = 0}})
	testing.expect_value(t, serr, linux.Errno.NONE)

	index, gen := unpack_user_data(id)
	stale := linux.IO_Uring_CQE{user_data = pack_user_data(index, gen + 1), res = 123}

	_, ok := resolve_cqe(&r, stale)
	testing.expect(t, !ok, "stale-generation CQE should be dropped")
}

@(test)
test_resolve_cqe_valid_frees_slot :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	buf: [8]u8
	id, serr := ring_submit(&r, Request{fiber = 9, params = Read_Params{fd = 0, buf = buf[:], offset = 0}})
	testing.expect_value(t, serr, linux.Errno.NONE)

	before := r.free_top
	cqe := linux.IO_Uring_CQE{user_data = id, res = 5}

	c, ok := resolve_cqe(&r, cqe)
	testing.expect(t, ok, "valid CQE should resolve")
	testing.expect_value(t, c.fiber, Fiber_Id(9))
	testing.expect_value(t, c.result, i32(5))
	testing.expect_value(t, r.free_top, before + 1)
}

// Proves Raw_Params can drive an op ring.odin has no built-in knowledge of
// (openat here) — the whole point of generalizing Request_Params.
@(test)
test_ring_submit_raw_openat :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	path: cstring = "/dev/null"

	build_openat :: proc(ring: ^uring.Ring, user_data: u64, ctx: rawptr) -> (sqe: ^linux.IO_Uring_SQE, ok: bool) {
		p := (^cstring)(ctx)
		return uring.openat(ring, user_data, linux.AT_FDCWD, p^, {}, {})
	}

	_, serr := ring_submit(&r, Request{fiber = 99, params = Raw_Params{build = build_openat, ctx = &path}})
	testing.expect_value(t, serr, linux.Errno.NONE)

	out: Completions
	defer delete(out)
	cn, derr := ring_drain(&r, &out, 1)
	testing.expect_value(t, derr, linux.Errno.NONE)
	testing.expect_value(t, cn, u32(1))
	result, ok := out[99]
	testing.expect(t, ok, "fiber 99 should have a completion")
	testing.expect(t, result >= 0, "openat via Raw_Params should return a valid fd")

	if result >= 0 {
		linux.close(linux.Fd(result))
	}
}

@(test)
test_ring_accept_connect_send_recv :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	listen_fd, lferr := linux.socket(.INET, .STREAM, {}, .TCP)
	testing.expect_value(t, lferr, linux.Errno.NONE)
	defer linux.close(listen_fd)

	listen_addr := linux.Sock_Addr_In{sin_family = .INET, sin_port = 0, sin_addr = {127, 0, 0, 1}}
	testing.expect_value(t, linux.bind(listen_fd, &listen_addr), linux.Errno.NONE)
	testing.expect_value(t, linux.listen(listen_fd, 1), linux.Errno.NONE)

	bound: linux.Sock_Addr_Any
	testing.expect_value(t, linux.getsockname(listen_fd, &bound), linux.Errno.NONE)

	client_fd, cferr := linux.socket(.INET, .STREAM, {}, .TCP)
	testing.expect_value(t, cferr, linux.Errno.NONE)
	defer linux.close(client_fd)

	connect_addr := linux.Sock_Addr_Any{ipv4 = {sin_family = .INET, sin_port = bound.ipv4.sin_port, sin_addr = {127, 0, 0, 1}}}

	accept_id, aerr := ring_submit(&r, Request{fiber = 1, params = Accept_Params{fd = listen_fd, addr = nil, addr_len = nil}})
	testing.expect_value(t, aerr, linux.Errno.NONE)
	connect_id, cerr := ring_submit(&r, Request{fiber = 2, params = Connect_Params{fd = client_fd, addr = &connect_addr}})
	testing.expect_value(t, cerr, linux.Errno.NONE)

	out: Completions
	defer delete(out)

	// ring_drain clears `out` on every call, so results have to be copied
	// out before the next call wipes them — can't just keep re-reading
	// out[fiber] across iterations.
	got_accept, got_connect: bool
	accept_result, connect_result: i32
	for !got_accept || !got_connect {
		_, derr := ring_drain(&r, &out, 1)
		testing.expect_value(t, derr, linux.Errno.NONE)
		if v, ok := out[1]; ok {
			accept_result = v
			got_accept = true
		}
		if v, ok := out[2]; ok {
			connect_result = v
			got_connect = true
		}
	}
	testing.expect(t, accept_result >= 0, "accept should return a valid fd")
	testing.expect_value(t, connect_result, i32(0))
	accepted_fd := linux.Fd(accept_result)
	defer linux.close(accepted_fd)
	_, _ = accept_id, connect_id

	msg := transmute([]u8)string("ping")
	recv_buf: [16]u8

	_, serr := ring_submit(&r, Request{fiber = 3, params = Send_Params{fd = client_fd, buf = msg}})
	testing.expect_value(t, serr, linux.Errno.NONE)
	_, rerr := ring_submit(&r, Request{fiber = 4, params = Recv_Params{fd = accepted_fd, buf = recv_buf[:]}})
	testing.expect_value(t, rerr, linux.Errno.NONE)

	got_send, got_recv: bool
	send_result, recv_result: i32
	for !got_send || !got_recv {
		_, derr := ring_drain(&r, &out, 1)
		testing.expect_value(t, derr, linux.Errno.NONE)
		if v, ok := out[3]; ok {
			send_result = v
			got_send = true
		}
		if v, ok := out[4]; ok {
			recv_result = v
			got_recv = true
		}
	}
	testing.expect_value(t, send_result, i32(len(msg)))
	testing.expect_value(t, recv_result, i32(len(msg)))
	testing.expect_value(t, string(recv_buf[:recv_result]), "ping")
}

@(test)
test_ring_cancel :: proc(t: ^testing.T) {
	r: Ring
	err := ring_init(&r)
	testing.expect_value(t, err, linux.Errno.NONE)
	defer ring_deinit(&r)

	pair: [2]linux.Fd
	testing.expect_value(t, linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair), linux.Errno.NONE)
	defer linux.close(pair[0])
	defer linux.close(pair[1])

	// Nothing will ever be written to pair[0], so this recv sits in flight
	// until it's explicitly canceled.
	buf: [16]u8
	recv_id, rerr := ring_submit(&r, Request{fiber = 10, params = Recv_Params{fd = pair[0], buf = buf[:]}})
	testing.expect_value(t, rerr, linux.Errno.NONE)

	_, cerr := ring_submit(&r, Request{fiber = 11, params = Cancel_Params{target = recv_id}})
	testing.expect_value(t, cerr, linux.Errno.NONE)

	out: Completions
	defer delete(out)

	got_recv, got_cancel: bool
	recv_result, cancel_result: i32
	for !got_recv || !got_cancel {
		_, derr := ring_drain(&r, &out, 1)
		testing.expect_value(t, derr, linux.Errno.NONE)
		if v, ok := out[10]; ok {
			recv_result = v
			got_recv = true
		}
		if v, ok := out[11]; ok {
			cancel_result = v
			got_cancel = true
		}
	}
	testing.expect_value(t, recv_result, -i32(linux.Errno.ECANCELED))
	testing.expect(t, cancel_result == 0 || cancel_result == -i32(linux.Errno.EALREADY), "cancel should report success or already-in-flight")
}
