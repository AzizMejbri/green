package green

/* Rt_Config tunes the resource limits of one runtime instance. */
Rt_Config :: struct {
    // Starting capacity of the run queue. Not a hard limit: the run queue is a
    // queue.Queue, which grows automatically past this if more tasks are ever
    // ready at once. Sizing it close to your expected peak just avoids a few
    // reallocations early on.
    max_fibers: int,

    // Hard cap on how many io_uring operations may be in flight at once.
    // Submitting past this returns ENOMEM rather than growing further --
    // unlike max_fibers, this really is a limit, not just a sizing hint.
    max_requests: u32,

    // Default task stack size, used whenever spawn/sched_spawn is not given
    // an explicit stack_size.
    default_stack_size: uint,
}

RT_DEFAULT_CONFIG :: Rt_Config{
  max_fibers         = 1024,
  max_requests       = 4096,
  default_stack_size = 8 * 1024,
}
