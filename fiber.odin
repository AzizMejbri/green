package green

import "base:runtime"

// Fiber_Id identifies one green task. IDs are assigned when a task is created
// and are unique among tasks alive at the same time.
Fiber_Id :: uint

// Fiber_State is the scheduler's view of a task.
//
// READY means it can run, RUNNING means it currently owns the CPU, BLOCKED
// means it is waiting for something, and FINISHED means it has stopped.
Fiber_State :: enum {
  READY, RUNNING, BLOCKED, FINISHED
}

// Fiber is one green task: its stack, saved CPU state, and the bookkeeping
// needed to start it and clean it up.
//
// Fibers live on the heap because the run queue, the blocked set, and the
// scheduler's current-task pointer all refer to the same task by address.
// Copying a Fiber would break those references.
Fiber :: struct {
  id:     Fiber_Id,
  stack:  Stack,
  ctx:    Context,
  state:  Fiber_State,
  resume: i32, // result copied in when a blocking operation completes

  // entry is a small internal adapter with a uniform signature. The user's
  // real task body is stored type-erased in entry_fn (and its argument in arg)
  // because all fibers must have the same concrete type even when their task
  // bodies accept different argument types.
  entry:    proc(^Fiber),
  entry_fn: rawptr,
  arg:      any,

  sched:    ^Scheduler,
  odin_ctx: runtime.Context, // the spawning task's context, inherited at start
}

// Next ID to hand out. The runtime has one scheduler, so this does not need
// atomic updates.
FIBERS_LAST_ID := 1

// The task that is about to enter for the first time. This is read only by
// fiber_trampoline, immediately after a fresh task is switched to.
@(private)
g_entering_fiber: ^Fiber

// fiber_trampoline is the first code that runs on a new task's stack. It uses C
// calling convention because context_init starts it by returning into it, not
// by making an ordinary Odin call. It installs the inherited Odin context, runs
// the user's task body, and then exits the task.
@(private)
fiber_trampoline :: proc "c" () {
  f := g_entering_fiber
  context = f.odin_ctx
  f.entry(f)
  sched_kill(f.sched)
}

// call_entry_noargs runs a task body that takes no arguments.
@(private)
call_entry_noargs :: proc(f: ^Fiber) {
  fn := cast(proc())(f.entry_fn)
  fn()
}

// fiber_alloc creates the shared parts of every task: a stable heap object, an
// ID, a fresh stack, and a context that will enter fiber_trampoline. The
// spawning task's Odin context is inherited so allocators, loggers, and similar
// per-context values behave as the caller expects.
@(private)
fiber_alloc :: proc(sched: ^Scheduler, stack_size: uint) -> ^Fiber {
  f := new(Fiber)
  ensure(f != nil, "fiber_init(): OOM allocating a fiber object")
  f.id = Fiber_Id(FIBERS_LAST_ID)
  f.state = .READY
  f.sched = sched
  f.odin_ctx = context
  stack, ok := stack_alloc(stack_size)
  ensure(ok, "fiber_init(): OOM: Error allocating space for fiber stack")
  f.stack = stack
  context_init(&f.ctx, stack, rawptr(fiber_trampoline))
  FIBERS_LAST_ID += 1
  return f
}

// fiber_init_noargs creates a task whose body takes no arguments.
fiber_init_noargs :: proc(sched: ^Scheduler, entry: proc(), stack_size: uint = DEFAULT_STACK) -> ^Fiber {
  f := fiber_alloc(sched, stack_size)
  f.entry = call_entry_noargs
  f.entry_fn = rawptr(entry)
  return f
}

// fiber_init_with_arg creates a task and gives it a private copy of args.
//
// Odin procedures do not capture their surroundings, so the argument is the
// task's only way to receive data from its creator. It is cloned onto the heap
// and recovered later with a checked type assertion.
fiber_init_with_arg :: proc(sched: ^Scheduler, entry: proc(args: $T), args: T, stack_size: uint = DEFAULT_STACK) -> ^Fiber {
  call_entry :: proc(f: ^Fiber) {
    fn := cast(proc(T))(f.entry_fn)
    fn(f.arg.(T))
  }
  f := fiber_alloc(sched, stack_size)
  f.entry = call_entry
  f.entry_fn = rawptr(entry)

  // new_clone returns a pointer to the copy. Storing the dereferenced value in
  // an any keeps that same heap address, so there is only one copy to free.
  arg := new_clone(args)
  ensure(arg != nil, "fiber_init(): OOM copying the fiber argument")
  f.arg = arg^
  return f
}

// fiber_init creates either kind of task. This overload mirrors green.spawn.
fiber_init :: proc{fiber_init_noargs, fiber_init_with_arg}

// fiber_deinit releases everything owned by a finished task: its argument copy,
// its stack, and the Fiber object itself.
//
// This must run on the scheduler's stack, never on the task's own stack,
// because the task's stack is about to be unmapped.
fiber_deinit :: proc(f: ^Fiber) {
  free(f.arg.data) // no-op on the no-argument path
  stack_free(f.stack)
  free(f)
}
