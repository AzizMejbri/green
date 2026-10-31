package green

import "core:container/queue"
import "core:sync"

// A Waiter is one task's place in a wait queue. Waiter nodes are allocated
// only when a task actually has to wait, then freed when it is woken. Waiting
// is uncommon compared with the scheduler's hot path, so a small allocation
// here keeps the queue simple.
@(private)
Waiter :: struct {
  fiber: ^Fiber,
  next:  ^Waiter,
}

// Wait_Queue is a first-in, first-out list of tasks waiting for the same
// thing. Channels use one queue for senders waiting for space and another for
// receivers waiting for a value.
Wait_Queue :: struct {
  head, tail: ^Waiter,
}

@(private)
waitq_push :: proc(wq: ^Wait_Queue, f: ^Fiber) {
  w := new(Waiter)
  ensure(w != nil, "channel: OOM allocating a wait-queue node")
  w.fiber = f
  if wq.tail != nil {
    wq.tail.next = w
  } else {
    wq.head = w
  }
  wq.tail = w
}

// waitq_pop removes and returns the task that has been waiting the longest.
// The caller owns the returned fiber reference; the queue node itself is freed
// here.
@(private)
waitq_pop :: proc(wq: ^Wait_Queue) -> (f: ^Fiber, ok: bool) {
  if wq.head == nil {
    return nil, false
  }
  w := wq.head
  wq.head = w.next
  if wq.head == nil {
    wq.tail = nil
  }
  f = w.fiber
  free(w)
  ok = true
  return
}

// wake_one marks the oldest waiting task as ready and puts it back on its
// scheduler's run queue. Only one task is woken: one free channel slot or one
// new value can only help one waiter. The task is not switched to immediately;
// it simply becomes runnable again.
@(private)
wake_one :: proc(wq: ^Wait_Queue) {
  if f, ok := waitq_pop(wq); ok {
    f.state = .READY
    pushed, _ := queue.push_back(&f.sched.runq, f)
    ensure(pushed, "channel: OOM growing the run queue while waking a waiter")
  }
}

// Chan is a fixed-capacity channel carrying values of type T.
//
// N is the number of values the channel can hold. It must be at least 1.
// A zero-value Chan is ready to use:
//
//     ch: green.Chan(int, 16)
//
// Sends and receives are first-in, first-out. If the channel is full,
// chan_send waits. If it is empty, chan_recv waits. A waiting task does not
// spin; it is parked and woken when the other side makes progress.
//
// Use a channel from green tasks. Do not share it between independent operating
// system threads.
Chan :: struct($T: typeid, $N: uint) {
  buf:   [N]T,
  head:  uint, // next position to read
  tail:  uint, // next position to write
  sendq: Wait_Queue, // tasks waiting because the channel is full
  recvq: Wait_Queue, // tasks waiting because the channel is empty
}

// chan_send_priv tries to send without waiting. It returns false when the
// channel is full. A successful send also wakes one waiting receiver, since a
// value is now available.
//
// This is the non-blocking building block behind sched_chan_send. It is also
// usable directly in tests and in code that wants to poll a channel.
chan_send_priv :: proc(c: ^Chan($T, $N), x: T) -> bool {
  t := sync.atomic_load_explicit(&c.tail, .Relaxed)
  h := sync.atomic_load_explicit(&c.head, .Acquire)

  if t - h == N {
    return false // full
  }

  c.buf[t & (N-1)] = x
  sync.atomic_store_explicit(&c.tail, t + 1, .Release)
  wake_one(&c.recvq)
  return true
}

// chan_recv_priv tries to receive without waiting. It returns false when the
// channel is empty. A successful receive also wakes one waiting sender, since
// a slot is now free.
//
// This is the non-blocking building block behind sched_chan_recv.
chan_recv_priv :: proc(c: ^Chan($T, $N)) -> (T, bool) {
  h := sync.atomic_load_explicit(&c.head, .Relaxed)
  t := sync.atomic_load_explicit(&c.tail, .Acquire)

  if h == t {
    return {}, false
  }

  result := c.buf[h & (N-1)]
  sync.atomic_store_explicit(&c.head, h + 1, .Release)
  wake_one(&c.sendq)
  return result, true
}

// sched_chan_send sends a value, waiting if the channel is full.
//
// Waiting means parking the current task: it leaves the run queue, the
// scheduler switches to another task, and this function continues only after a
// receiver frees a slot. The loop matters because a woken sender can lose the
// race for the free slot to another sender; if that happens it waits again.
//
// Call this only from a green task.
sched_chan_send :: proc(s: ^Scheduler, c: ^Chan($T, $N), v: T) {
  for {
    if chan_send_priv(c, v) {
      return
    }
    target := s.current
    target.state = .BLOCKED
    waitq_push(&c.sendq, target)
    switch_ctx(&target.ctx, &s.sched_ctx)
    // A receiver woke us by moving this task back to the run queue. The
    // scheduler will return here when it is this task's turn again.
  }
}

// sched_chan_recv receives a value, waiting if the channel is empty.
//
// It follows the same park-and-retry pattern as sched_chan_send: after waking,
// another receiver may have taken the value first, so it checks again.
//
// Call this only from a green task.
sched_chan_recv :: proc(s: ^Scheduler, c: ^Chan($T, $N)) -> T {
  for {
    if v, ok := chan_recv_priv(c); ok {
      return v
    }
    target := s.current
    target.state = .BLOCKED
    waitq_push(&c.recvq, target)
    switch_ctx(&target.ctx, &s.sched_ctx)
  }
}
