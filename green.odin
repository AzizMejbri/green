// Package green gives your program lightweight tasks that can wait for
// something to happen without stopping everything else.
//
// A green task behaves like a small, independent piece of work. When it has
// nothing useful to do -- because it is waiting for a file, a socket, a timer,
// or a message from another task -- it steps aside and lets another task run.
// When the thing it was waiting for is ready, it continues from where it
// stopped.
//
// A small program looks like this:
//
//     green.rt_init()
//     defer green.rt_deinit()
//
//     green.spawn(worker)
//     green.run()
//
// Tasks are cooperative: they keep running until they finish, wait, or call
// green.yield(). There is no forced preemption, so a task that never waits or
// yields will keep the others waiting. Keep long CPU-heavy loops cooperative
// by yielding regularly.
package green

// The runtime's shared state. Most users should use the functions below
// instead of touching this directly.
g_scheduler: Scheduler

// rt_init prepares the runtime for use. Call it once, before spawning tasks or
// calling any other runtime function.
//
// cfg tunes resource limits -- see Rt_Config. The default, RT_DEFAULT_CONFIG,
// matches this project's original hardcoded limits, so existing callers that
// pass nothing behave exactly as before Rt_Config existed.
//
// Pair it with rt_deinit when the program is done:
//
//     green.rt_init()
//     defer green.rt_deinit()
rt_init :: #force_inline proc(cfg: Rt_Config = RT_DEFAULT_CONFIG) {
  sched_init(&g_scheduler, cfg)
}

// rt_deinit releases resources owned by the runtime. Call it after run has
// returned (or after you have stopped using the runtime).
rt_deinit :: #force_inline proc() {
  sched_deinit(&g_scheduler)
}

// run starts running tasks and keeps going until every spawned task has
// finished.
//
// run does not return just because all currently runnable tasks are waiting.
// A task waiting for I/O, a timer, or a channel message still counts as alive,
// so the runtime waits for it to wake up and finish.
run :: #force_inline proc() {
  _run(&g_scheduler)
}

// spawn_noargs starts a task that takes no arguments.
//
// The optional stack_size is the amount of stack space reserved for the task.
// The default is small and is intended for ordinary code. Increase it for a
// task that uses deep recursion, large local values, or libraries that need
// more stack. Stack memory is released when the task finishes.
//
// Prefer the overload named spawn, which accepts both task forms.
spawn_noargs :: #force_inline proc(entry: proc(), stack_size: uint = DEFAULT_STACK) {
  sched_spawn(&g_scheduler, entry, stack_size)
}

// spawn_with_arg starts a task and gives it one value of its own.
//
// The argument is copied into the task before it starts, so passing a
// temporary value or a local variable is safe:
//
//     green.spawn(worker, Worker_Args{count = 5})
//
// The task can change its copy without affecting the caller. If several tasks
// need to share changing data, pass a pointer inside the argument and protect
// the shared data appropriately.
//
// Prefer the overload named spawn, which accepts both task forms.
spawn_with_arg :: #force_inline proc(entry: proc(args: $T), args: T, stack_size: uint = DEFAULT_STACK) {
  sched_spawn(&g_scheduler, entry, args, stack_size)
}

// spawn starts a new task. Use this overload with either a task that takes no
// arguments or a task that takes one argument:
//
//     green.spawn(worker)
//     green.spawn(worker, args)
//
// The task begins running the next time the runtime gets a chance to run it.
spawn :: proc{spawn_noargs, spawn_with_arg}

// exit ends the current task immediately.
//
// Unlike returning normally from a task, exit does not run deferred statements
// in the task. Use it for early exits only when you do not need cleanup, or
// perform cleanup explicitly before calling it.
exit :: #force_inline proc() {
  sched_kill(&g_scheduler)
}

// yield gives other ready tasks a chance to run.
//
// The current task is placed back in the ready queue and will run again later.
// If it is the only ready task, it may continue almost immediately. Call yield
// inside long loops that do not otherwise wait.
yield :: #force_inline proc() {
  sched_yield(&g_scheduler)
}

// request waits for an operating-system operation to finish.
//
// The argument describes the operation: a read, a write, a timer, a socket
// operation, or a custom operation. While the operation is in progress, the
// current task waits and other tasks continue running.
//
// The return value is the raw result from the operating system. Zero or a
// positive number usually means success (for example, the number of bytes
// transferred). A negative value is an error code.
//
// Example:
//
//     params: green.Request_Params = green.Timeout_Params{ns = 10_000_000}
//     result := green.request(&params)
request :: #force_inline proc(req: ^Request_Params) -> i32 {
  return sched_block(&g_scheduler, req^)
}

// chan_send sends a value to a channel.
//
// If the channel has room, the value is stored immediately. If it is full, the
// current task waits until another task receives a value and makes room.
chan_send :: #force_inline proc(chan: ^Chan($T, $N), v: T) {
  sched_chan_send(&g_scheduler, chan, v)
}

// chan_recv receives the next value from a channel.
//
// If a value is available, it is returned immediately. If the channel is
// empty, the current task waits until another task sends a value.
chan_recv :: #force_inline proc(chan: ^Chan($T, $N)) -> T {
  return sched_chan_recv(&g_scheduler, chan)
}

// get_id returns the current task's identifier.
//
// Identifiers are unique among tasks that are alive at the same time. They are
// useful for logging and for maps keyed by task. Do not use an identifier
// after its task has finished.
get_id :: #force_inline proc() -> Fiber_Id {
  ensure(g_scheduler.current != nil, "a nil fiber tried to call from its id somehow")
  return g_scheduler.current.id
}
