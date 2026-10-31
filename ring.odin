package green

import "core:sys/linux"
import "core:sys/linux/uring"

// Read_Params reads bytes from a file descriptor into buf, starting at offset.
Read_Params :: struct {
	fd:     linux.Fd,
	buf:    []u8,
	offset: u64,
}

// Write_Params writes buf to a file descriptor, starting at offset.
Write_Params :: struct {
	fd:     linux.Fd,
	buf:    []u8,
	offset: u64,
}

// Timeout_Params waits for ns nanoseconds. A timeout completion is reported
// like any other operation result.
Timeout_Params :: struct {
	ns: uint,
}

// Accept_Params accepts a connection on a listening socket.
//
// addr and addr_len may both be nil when the caller does not need the peer
// address. When supplied, the kernel writes the peer address there.
Accept_Params :: struct {
	fd:       linux.Fd,
	addr:     ^linux.Sock_Addr_Any,
	addr_len: ^i32,
}

// Recv_Params receives bytes from a socket into buf.
Recv_Params :: struct {
	fd:  linux.Fd,
	buf: []u8,
}

// Send_Params sends bytes from buf over a socket.
Send_Params :: struct {
	fd:  linux.Fd,
	buf: []u8,
}

// Connect_Params connects a socket to addr.
Connect_Params :: struct {
	fd:   linux.Fd,
	addr: ^linux.Sock_Addr_Any,
}

// Cancel_Params asks the kernel to cancel an in-flight request. target is the
// id returned by ring_submit for the request being cancelled.
//
// The cancellation itself also produces a completion: zero means the request
// was cancelled, -ENOENT means it was not found, and -EALREADY means it was
// already in progress.
Cancel_Params :: struct {
	target: u64,
}

// Raw_Params is the escape hatch for any io_uring operation that does not have
// a named parameter type here.
//
// Odin procedures do not capture surrounding variables, so the builder receives
// an explicit ctx pointer supplied by the caller. That pointer must stay valid
// until the operation completes. This keeps the runtime open-ended without
// requiring a new case in ring_submit for every io_uring call.
Raw_Params :: struct {
	build: proc(ring: ^uring.Ring, user_data: u64, ctx: rawptr) -> (sqe: ^linux.IO_Uring_SQE, ok: bool),
	ctx:   rawptr,
}

// Request_Params describes one operation to submit to io_uring.
Request_Params :: union {
	Read_Params,
	Write_Params,
	Timeout_Params,
	Accept_Params,
	Recv_Params,
	Send_Params,
	Connect_Params,
	Cancel_Params,
	Raw_Params,
}

// Request pairs an operation with the task that should be woken when it
// completes.
Request :: struct {
	fiber:  Fiber_Id,
	params: Request_Params,
}

@(private = "file")
Completion :: struct {
	fiber:  Fiber_Id,
	result: i32,
}

// Completions maps a task ID to the raw result of its operation.
//
// A value of zero or greater means success (often a byte count). A negative
// value is a negated errno, the same convention io_uring uses.
Completions :: map[Fiber_Id]i32

// Number of completion entries copied out of the kernel ring per drain.
DRAIN_BATCH :: 128

// A slot tracks one in-flight request. The generation counter makes handles
// safe against reuse: an old completion carrying a stale generation is ignored
// instead of waking the wrong task.
@(private)
Slot :: struct {
	fiber: Fiber_Id,
	gen:   u32,
	used:  bool,
	ts:    linux.Time_Spec, // storage for Timeout_Params while the op is active
}

// Ring owns the io_uring instance and the pool of in-flight requests. slots
// and free are sized once, at ring_init, from Rt_Config.max_requests -- a
// runtime value, which is why they are slices rather than fixed-size arrays.
Ring :: struct {
	ring:      uring.Ring,
	slots:     []Slot,
	free:      []u32,
	free_top:  u32,
	cqe_batch: [DRAIN_BATCH]linux.IO_Uring_CQE,
}

// pack_user_data combines a slot index and generation into the u64 value that
// io_uring carries back in each completion.
@(private)
pack_user_data :: #force_inline proc(index: u32, gen: u32) -> u64 {
	return u64(gen) << 32 | u64(index)
}

// unpack_user_data splits an io_uring user_data value back into its slot index
// and generation.
@(private)
unpack_user_data :: #force_inline proc(user_data: u64) -> (index: u32, gen: u32) {
	index = u32(user_data & 0xffff_ffff)
	gen = u32(user_data >> 32)
	return
}

// ring_init creates the io_uring instance and the free-slot pool.
//
// max_requests sets the hard cap on simultaneously in-flight operations --
// see Rt_Config.max_requests. Returns the kernel error from io_uring setup,
// or nil on success.
ring_init :: proc(r: ^Ring, max_requests: u32 = RT_DEFAULT_CONFIG.max_requests) -> linux.Errno {
	params := uring.DEFAULT_PARAMS
	err := uring.init(&r.ring, &params)
	if err != nil {return err}

	r.slots = make([]Slot, max_requests)
	r.free = make([]u32, max_requests)
	if len(r.slots) != int(max_requests) || len(r.free) != int(max_requests) {
		delete(r.slots)
		delete(r.free)
		uring.destroy(&r.ring)
		return .ENOMEM
	}

	for i in 0 ..< max_requests {
		r.free[i] = i
	}
	r.free_top = max_requests
	return nil
}

// ring_deinit destroys the io_uring instance and frees the slot pool. No
// requests should still be in flight when this is called.
ring_deinit :: proc(r: ^Ring) {
	uring.destroy(&r.ring)
	delete(r.slots)
	delete(r.free)
}

// ring_submit queues one operation for the kernel.
//
// It returns a handle that can be used to cancel the operation, or an error:
// ENOMEM when every slot is busy (see Rt_Config.max_requests), and EAGAIN
// when io_uring's submission queue is full or the operation could not be
// prepared.
//
// The caller is responsible for keeping every buffer and pointer in the request
// valid until the operation completes.
ring_submit :: proc(r: ^Ring, req: Request) -> (id: u64, err: linux.Errno) {
	if r.free_top == 0 {
		err = .ENOMEM
		return
	}

	r.free_top -= 1
	index := r.free[r.free_top]
	slot := &r.slots[index]
	slot.fiber = req.fiber
	slot.used = true

	user_data := pack_user_data(index, slot.gen)

	ok: bool
	switch p in req.params {
	case Read_Params:
		_, ok = uring.read(&r.ring, user_data, p.fd, p.buf, p.offset)
	case Write_Params:
		_, ok = uring.write(&r.ring, user_data, p.fd, p.buf, p.offset)
	case Timeout_Params:
		slot.ts = linux.Time_Spec {
			time_sec  = p.ns / 1_000_000_000,
			time_nsec = p.ns % 1_000_000_000,
		}
		_, ok = uring.timeout(&r.ring, user_data, &slot.ts, 0, {})
	case Accept_Params:
		_, ok = uring.accept(&r.ring, user_data, p.fd, p.addr, p.addr_len, {})
	case Recv_Params:
		_, ok = uring.recv(&r.ring, user_data, p.fd, p.buf, {})
	case Send_Params:
		_, ok = uring.send(&r.ring, user_data, p.fd, p.buf, {})
	case Connect_Params:
		_, ok = uring.connect(&r.ring, user_data, p.fd, p.addr)
	case Cancel_Params:
		_, ok = uring.async_cancel(&r.ring, p.target, user_data)
	case Raw_Params:
		_, ok = p.build(&r.ring, user_data, p.ctx)
	}

	if !ok {
		// Preparing the operation failed, so give the slot back immediately.
		slot.used = false
		r.free[r.free_top] = index
		r.free_top += 1
		err = .EAGAIN
		return
	}

	id = user_data
	return
}

// resolve_cqe turns one kernel completion into a task result and returns its
// slot to the free pool.
//
// The generation check is what makes stale completions harmless: if a slot was
// reused before an old completion arrived, the generation no longer matches and
// the completion is ignored.
@(private)
resolve_cqe :: proc(r: ^Ring, cqe: linux.IO_Uring_CQE) -> (c: Completion, ok: bool) {
	index, gen := unpack_user_data(cqe.user_data)
	slot := &r.slots[index]

	if !slot.used || slot.gen != gen {
		return
	}

	c = Completion {
		fiber  = slot.fiber,
		result = cqe.res,
	}
	ok = true

	slot.used = false
	slot.gen += 1
	r.free[r.free_top] = index
	r.free_top += 1
	return
}

// ring_drain collects completed operations into out, keyed by task ID.
//
// wait_nr controls how long the kernel may block:
//   - 0 means check for work and return immediately;
//   - a positive value waits for at least that many completions.
//
// Pending submissions are flushed only when there is something to submit or
// when the caller explicitly asked to wait, so the common "nothing to do" path
// does not pay for an unnecessary syscall.
//
// The function returns the number of completions resolved and any kernel error.
// out is cleared at the start of every call.
ring_drain :: proc(r: ^Ring, out: ^Completions, wait_nr: u32 = 0) -> (n: u32, err: linux.Errno) {
	clear(out)

	// Avoid a syscall when the submission queue is empty and the caller is not
	// asking us to wait.
	if uring.sq_ready(&r.ring) > 0 || wait_nr > 0 {
		_, err = uring.submit(&r.ring, wait_nr)
		if err != nil {return}
	}

	copied := uring.copy_cqes_ready(&r.ring, r.cqe_batch[:])

	for i in 0 ..< copied {
		if c, ok := resolve_cqe(r, r.cqe_batch[i]); ok {
			out[c.fiber] = c.result
			n += 1
		}
	}

	return
}
