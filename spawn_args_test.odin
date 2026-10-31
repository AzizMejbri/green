package green

import "core:testing"

@(private = "file")
Greet_Args :: struct {
  id:  int,
  out: ^[2]int, // slot `id` writes into, so the test can see both fibers actually ran with their own data
}

@(private = "file")
greet :: proc(a: Greet_Args) {
  a.out[a.id] = a.id * 100
}

@(test)
test_spawn_with_arg_gives_each_fiber_its_own_data :: proc(t: ^testing.T) {
  out: [2]int

  s: Scheduler
  sched_init(&s)
  defer sched_deinit(&s)

  sched_spawn(&s, greet, Greet_Args{id = 0, out = &out})
  sched_spawn(&s, greet, Greet_Args{id = 1, out = &out})
  _run(&s)

  testing.expect_value(t, out[0], 0)
  testing.expect_value(t, out[1], 100)
}
