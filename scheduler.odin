package green

import "core:container/queue"

// Scheduler owns everything needed to run green tasks on one operating-system
// thread: the io_uring instance, the ready queue, and the bookkeeping for tasks
// waiting on I/O.
Scheduler :: struct {
  // the io_uring abstraction, owned by the scheduler
  ring: Ring,

  // Where the scheduler resumes when a running task gives up control. It does
  // not need its own stack; switching into a task records the scheduler's exact
  // resume point here.
  sched_ctx: Context,

  // tasks in the .READY state, waitin in the runqueue
  runq:  queue.Queue(^Fiber),

  // completions from the most recent ring_drain
  waitq: Completions, 

  // tasks waiting for an I/O completion, in the .BLOCKED state
  blocked: map[Fiber_Id]^Fiber, 

  // current fiber having the CPU allocated to it, in the .RUNNING state
  current: ^Fiber,

  // Number of spawned tasks that have not finished yet. A task waiting on a
  // channel is neither runnable nor waiting on I/O, so checking only the run
  // queue and blocked map would make run() exit too early. This counter keeps
  // the runtime alive until every task is truly done.
  alive: int,
}

// sched_init creates the io_uring instance and the scheduler's bookkeeping,
// sized according to cfg
sched_init :: proc(s: ^Scheduler, cfg: Rt_Config = RT_DEFAULT_CONFIG) {
  DEFAULT_STACK = cfg.default_stack_size

  err := ring_init(&s.ring, cfg.max_requests)
  ensure(err == .NONE, "Error initializing the scheduler's uring, aborting ...")

  qerr := queue.init(&s.runq, cfg.max_fibers)
  ensure(qerr == nil, "Scheduler: failed to allocate the run queue")

  s.waitq = make(Completions)
  s.blocked = make(map[Fiber_Id]^Fiber)
}

// sched_deinit releases the ring, the run queue, and the scheduler's maps.
// All tasks should already have finished before this is called.
sched_deinit :: proc(s: ^Scheduler) {
  ring_deinit(&s.ring)
  queue.destroy(&s.runq)
  werr := delete(s.waitq)
  ensure(werr == nil)
  berr := delete(s.blocked)
  ensure(berr == nil)
}

// sched_spawn_finish places a newly created task on the run queue and records
// that one more task is alive. The run queue grows as needed, so failure
// here means real allocation failure, not a capacity limit -- ensure reports
// it loudly either way.
@(private = "file")
sched_spawn_finish :: proc(s: ^Scheduler, f: ^Fiber) -> ^Fiber {
  ok, _ := queue.push_back(&s.runq, f)
  ensure(ok, "Scheduler: Failed to push into the tasks runqueue ... Overflow")
  s.alive += 1
  return f
}

// sched_spawn_noargs creates a task whose body takes no arguments and marks it
// ready to run.
sched_spawn_noargs :: proc(s: ^Scheduler, entry: proc(), stack_size: uint = DEFAULT_STACK) -> ^Fiber {
  return sched_spawn_finish(s, fiber_init(s, entry, stack_size))
}

// sched_spawn_with_arg creates a task with a private copy of args and marks it
// ready to run. The caller may discard its own copy immediately after this
// returns, including when that copy was a temporary struct value.
sched_spawn_with_arg :: proc(s: ^Scheduler, entry: proc(args: $T), args: T, stack_size: uint = DEFAULT_STACK) -> ^Fiber {
  return sched_spawn_finish(s, fiber_init(s, entry, args, stack_size))
}

// sched_spawn creates either kind of task. This overload mirrors green.spawn.
sched_spawn :: proc{sched_spawn_noargs, sched_spawn_with_arg}

// sched_kill stops the current task. It never returns.
//
// The task's stack cannot be freed while the task is still running on it, so
// this only marks the task finished and jumps back to the scheduler. The
// scheduler frees the stack afterwards, from its own stack.
sched_kill :: proc(s: ^Scheduler) -> ! {
  ensure(s.current != nil, "Scheduler: tried to kill a fiber that doesn't exist")
  s.current.state = .FINISHED
  ld_ctx(&s.sched_ctx)
}

// sched_yield puts the current task back on the ready queue and lets the
// scheduler choose someone else. The task resumes here when it is selected
// again.
sched_yield :: proc(s: ^Scheduler) {
  ensure(s.current != nil, "Scheduler: tried yielding from a non-existing fiber")
  target := s.current
  target.state = .READY
  pushed, _ := queue.push_back(&s.runq, target)
  ensure(pushed, "Scheduler: OOM growing the run queue while yielding")
  switch_ctx(&target.ctx, &s.sched_ctx)
  // Execution continues here after the scheduler runs this task again.
}

// sched_block submits an io_uring request for the current task and suspends
// until the matching completion arrives. It returns the raw kernel result:
// zero or positive on success, negative for an error.
//
// The task is put in sched.blocked while it waits. Once ring_drain reports the
// completion, the scheduler moves the task back to the run queue.
sched_block :: proc(s: ^Scheduler, req: Request_Params) -> i32 {
  ensure(s.current != nil, "Scheduler: tried blocking from a non-existing fiber")
  target := s.current
  target.state = .BLOCKED
  _, serr := ring_submit(&s.ring, Request{fiber = target.id, params = req})
  ensure(serr == .NONE, "Scheduler: failed to submit a blocking request")
  s.blocked[target.id] = target

  for target.state == .BLOCKED {
    switch_ctx(&target.ctx, &s.sched_ctx)
    // The scheduler only switches back after wake_blocked has made this task
    // ready and put it on the run queue, so this is a real suspend.
  }

  return target.resume
}

// schedule runs one scheduling step:
//
//  1. collect any completed I/O without waiting;
//  2. wake the tasks those completions belong to;
//  3. pick the next ready task;
//  4. if nothing is ready, sleep in the kernel until something completes;
//  5. switch into the chosen task.
//
// It returns when that task yields, blocks, or finishes.
schedule :: proc(s: ^Scheduler) {
  ensure(s.current == nil, "Scheduler: tried scheduling while there is a current")

  // Check for completions without blocking first. Two CPU-only tasks yielding
  // to each other may never submit anything to io_uring, so waiting here would
  // sleep forever even though ready work exists.
  _, err := ring_drain(&s.ring, &s.waitq)
  ensure(err == .NONE, "Scheduler: uring error draining completions")
  wake_blocked(s)

  next, ok := queue.pop_front_safe(&s.runq)
  if !ok {
    // Nothing is ready. It is now safe (and efficient) to sleep in the kernel
    // until at least one completion arrives.
    _, werr := ring_drain(&s.ring, &s.waitq, 1)
    ensure(werr == .NONE, "Scheduler: uring error draining completions while idle")
    wake_blocked(s)
    next, ok = queue.pop_front_safe(&s.runq)
    ensure(ok, "Scheduler: woke from idle but the run queue is still empty")
  }

  next.state = .RUNNING
  s.current = next
  g_entering_fiber = next // only used the first time a fresh task is entered
  switch_ctx(&s.sched_ctx, &next.ctx)
  // Execution resumes here after the task gives up control.

  finished := s.current
  s.current = nil
  if finished.state == .FINISHED {
    s.alive -= 1
    fiber_deinit(finished) // safe: we are back on the scheduler's own stack
  }
}

// _run is the top-level loop. It keeps scheduling until every spawned task has
// finished.
_run :: proc(s: ^Scheduler) {
  for s.alive > 0 {
    schedule(s)
  }
}

// wake_blocked moves tasks whose I/O just completed from the blocked map back
// to the run queue, carrying the kernel result with them.
//
// ring_drain clears s.waitq on every call, so this must happen before the next
// drain; otherwise completions would be lost.
@(private = "file")
wake_blocked :: proc(s: ^Scheduler) {
  for id, result in s.waitq {
    if f, ok := s.blocked[id]; ok {
      f.resume = result
      f.state = .READY
      pushed, _ := queue.push_back(&s.runq, f)
      ensure(pushed, "Scheduler: OOM growing the run queue while waking a blocked fiber")
      delete_key(&s.blocked, id)
    }
  }
}
