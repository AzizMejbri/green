package utils

import "core:testing"

@(test)
test_rb_push_pop_fifo :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	testing.expect(t, rb_is_empty(&rb))
	_, ok := rb_pop(&rb)
	testing.expect(t, !ok, "pop on empty ring buffer should fail")

	testing.expect(t, rb_push(&rb, 1))
	testing.expect(t, rb_push(&rb, 2))
	testing.expect(t, rb_push(&rb, 3))

	v, vok := rb_pop(&rb)
	testing.expect(t, vok)
	testing.expect_value(t, v, 1)

	v, vok = rb_pop(&rb)
	testing.expect(t, vok)
	testing.expect_value(t, v, 2)

	v, vok = rb_pop(&rb)
	testing.expect(t, vok)
	testing.expect_value(t, v, 3)

	_, vok = rb_pop(&rb)
	testing.expect(t, !vok, "pop after draining should fail")
	testing.expect(t, rb_is_empty(&rb))
}

@(test)
test_rb_push_fails_when_full :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	testing.expect(t, rb_push(&rb, 1))
	testing.expect(t, rb_push(&rb, 2))
	testing.expect(t, rb_push(&rb, 3))
	testing.expect(t, rb_push(&rb, 4))

	testing.expect(t, rb_is_full(&rb))
	testing.expect(t, !rb_push(&rb, 5), "push on a full ring buffer should fail")

	v, ok := rb_pop(&rb)
	testing.expect(t, ok)
	testing.expect_value(t, v, 1)
	testing.expect(t, !rb_is_full(&rb))

	// freeing one slot should make room for exactly one more push
	testing.expect(t, rb_push(&rb, 5))
	testing.expect(t, !rb_push(&rb, 6), "ring buffer should be full again")
}

@(test)
test_rb_peek_does_not_mutate :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	_, ok := rb_peek(&rb)
	testing.expect(t, !ok, "peek on empty ring buffer should fail")

	testing.expect(t, rb_push(&rb, 10))
	testing.expect(t, rb_push(&rb, 20))

	v1, ok1 := rb_peek(&rb)
	testing.expect(t, ok1)
	testing.expect_value(t, v1, 10)

	// peeking twice must return the same thing — no mutation.
	v2, ok2 := rb_peek(&rb)
	testing.expect(t, ok2)
	testing.expect_value(t, v2, 10)

	v3, ok3 := rb_pop(&rb)
	testing.expect(t, ok3)
	testing.expect_value(t, v3, 10)
}

@(test)
test_rb_len_and_capacity :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	testing.expect_value(t, rb_capacity(&rb), uint(4))
	testing.expect_value(t, rb_len(&rb), uint(0))

	rb_push(&rb, 1)
	rb_push(&rb, 2)
	testing.expect_value(t, rb_len(&rb), uint(2))

	rb_pop(&rb)
	testing.expect_value(t, rb_len(&rb), uint(1))
}

@(test)
test_rb_clear :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	rb_push(&rb, 1)
	rb_push(&rb, 2)
	testing.expect(t, !rb_is_empty(&rb))

	rb_clear(&rb)
	testing.expect(t, rb_is_empty(&rb))
	testing.expect_value(t, rb_len(&rb), uint(0))
	_, ok := rb_pop(&rb)
	testing.expect(t, !ok, "pop after clear should fail")
}

// Keeps exactly 2 of 4 capacity occupied (push 1, pop 1, repeat) well past
// N+1 total operations, so head/tail cycle through the 5-slot backing
// array (N+1, for the empty/full sentinel) several times over without
// ever risking a false-full/overflow from this test's own math — proving
// the modulo indexing wraps correctly, not just within the first lap.
@(test)
test_rb_wraparound :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	next_push := 1
	next_expected_pop := 1

	testing.expect(t, rb_push(&rb, next_push)); next_push += 1
	testing.expect(t, rb_push(&rb, next_push)); next_push += 1

	for _ in 0 ..< 20 {
		testing.expect(t, rb_push(&rb, next_push))
		next_push += 1

		v, ok := rb_pop(&rb)
		testing.expect(t, ok)
		testing.expect_value(t, v, next_expected_pop)
		next_expected_pop += 1
	}

	// drain the 2 still buffered and confirm they're still in order
	for {
		v, ok := rb_pop(&rb)
		if !ok {
			break
		}
		testing.expect_value(t, v, next_expected_pop)
		next_expected_pop += 1
	}
	testing.expect_value(t, next_expected_pop, next_push)
}

@(test)
test_rb_iter_empty :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	it := rb_iter(&rb)
	_, ok := rb_iter_next(&it)
	testing.expect(t, !ok, "iterating an empty ring buffer should yield nothing")
}

@(test)
test_rb_iter_order :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	rb_push(&rb, 1)
	rb_push(&rb, 2)
	rb_push(&rb, 3)

	it := rb_iter(&rb)
	seen: [dynamic]int
	defer delete(seen)
	for v in rb_iter_next(&it) {
		append(&seen, v)
	}

	testing.expect_value(t, len(seen), 3)
	testing.expect_value(t, seen[0], 1)
	testing.expect_value(t, seen[1], 2)
	testing.expect_value(t, seen[2], 3)
}

@(test)
test_rb_iter_does_not_mutate :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	rb_push(&rb, 1)
	rb_push(&rb, 2)

	it := rb_iter(&rb)
	for _ in rb_iter_next(&it) {}

	// the buffer itself must be untouched by iteration
	testing.expect_value(t, rb_len(&rb), uint(2))
	v, ok := rb_pop(&rb)
	testing.expect(t, ok)
	testing.expect_value(t, v, 1)
}

@(test)
test_rb_iter_two_independent_iterators :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	rb_push(&rb, 1)
	rb_push(&rb, 2)

	it_a := rb_iter(&rb)
	it_b := rb_iter(&rb)

	va, oka := rb_iter_next(&it_a)
	testing.expect(t, oka)
	testing.expect_value(t, va, 1)

	// it_b hasn't been advanced yet — it should still start from the head.
	vb, okb := rb_iter_next(&it_b)
	testing.expect(t, okb)
	testing.expect_value(t, vb, 1)

	va, oka = rb_iter_next(&it_a)
	testing.expect(t, oka)
	testing.expect_value(t, va, 2)
}

@(test)
test_rb_iter_after_wraparound :: proc(t: ^testing.T) {
	rb: Ring_Buffer(int, 4)
	rb_init(&rb)

	// push/pop past the 5-slot backing array (N+1) to force head/tail to
	// wrap before anything is left to iterate over.
	for i in 1 ..= 6 {
		testing.expect(t, rb_push(&rb, i))
		v, ok := rb_pop(&rb)
		testing.expect(t, ok)
		testing.expect_value(t, v, i)
	}

	rb_push(&rb, 100)
	rb_push(&rb, 200)
	rb_push(&rb, 300)

	it := rb_iter(&rb)
	seen: [dynamic]int
	defer delete(seen)
	for v in rb_iter_next(&it) {
		append(&seen, v)
	}

	testing.expect_value(t, len(seen), 3)
	testing.expect_value(t, seen[0], 100)
	testing.expect_value(t, seen[1], 200)
	testing.expect_value(t, seen[2], 300)
}
