package utils

// Ring_Buffer is a fixed-capacity, first-in first-out queue.
//
// N is the number of values the queue can hold. The backing array uses N + 1
// slots and keeps one slot empty so "full" and "empty" can never look the same:
//
//     head == tail                 means empty
//     (tail + 1) % (N + 1) == head means full
//
// head is the next slot to read and tail is the next slot to write. No
// allocation happens after the value is created.
//
// A ring buffer is not internally synchronized. The scheduler uses one on a
// single thread, so callers that share one must provide their own locking.
Ring_Buffer :: struct($T: typeid, $N: uint) {
	buf:  [N + 1]T,
	head: uint,
	tail: uint,
}

// rb_init resets the buffer to empty.
rb_init :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) {
	rb.head = 0
	rb.tail = 0
}

// rb_clear empties the buffer without changing its capacity.
//
// It does not destroy or free values still in the backing array; callers that
// own non-trivial values should remove them first.
rb_clear :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) {
	rb.head = 0
	rb.tail = 0
}

// rb_is_empty reports whether the buffer contains no values.
rb_is_empty :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> bool {
	return rb.head == rb.tail
}

// rb_is_full reports whether the buffer has no room for another value.
rb_is_full :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> bool {
	return (rb.tail + 1) % (N + 1) == rb.head
}

// rb_len returns the number of values currently stored.
rb_len :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> uint {
	return (rb.tail + (N + 1) - rb.head) % (N + 1)
}

// rb_capacity returns the maximum number of values the buffer can hold.
rb_capacity :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> uint {
	return N
}

// rb_push adds v to the back of the queue. It returns false when the queue is
// full and leaves the buffer unchanged.
rb_push :: proc "contextless" (rb: ^Ring_Buffer($T, $N), v: T) -> bool {
	if rb_is_full(rb) {
		return false
	}
	rb.buf[rb.tail] = v
	rb.tail = (rb.tail + 1) % (N + 1)
	return true
}

// rb_pop removes and returns the value at the front of the queue. It returns
// ok = false when the queue is empty.
rb_pop :: proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> (v: T, ok: bool) {
	if rb_is_empty(rb) {
		return {}, false
	}
	v = rb.buf[rb.head]
	rb.head = (rb.head + 1) % (N + 1)
	return v, true
}

// rb_peek returns the value at the front without removing it. It returns
// ok = false when the queue is empty.
rb_peek :: proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> (v: T, ok: bool) {
	if rb_is_empty(rb) {
		return {}, false
	}
	return rb.buf[rb.head], true
}

// Ring_Buffer_Iter walks a ring buffer from head to tail without modifying it.
// The iterator keeps the buffer's type parameters so element size and capacity
// remain known.
Ring_Buffer_Iter :: struct($T: typeid, $N: uint) {
	rb:  ^Ring_Buffer(T, N),
	idx: uint,
}

// rb_iter creates a read-only iterator positioned at the front of the buffer.
//
//     it := rb_iter(&rb)
//     for value in rb_iter_next(&it) {
//         // use value
//     }
rb_iter :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> Ring_Buffer_Iter(T, N) {
	return Ring_Buffer_Iter(T, N){rb = rb, idx = rb.head}
}

// rb_iter_next returns the next value and advances the iterator. It returns
// ok = false after the last value.
rb_iter_next :: proc "contextless" (it: ^Ring_Buffer_Iter($T, $N)) -> (val: T, ok: bool) {
	if it.idx == it.rb.tail {
		return {}, false
	}
	val = it.rb.buf[it.idx]
	it.idx = (it.idx + 1) % (N + 1)
	ok = true
	return
}

// rb_iter_next_ptr returns a pointer to the next value and advances the
// iterator. It returns ok = false after the last value.
//
// The pointer is only valid until the buffer is modified.
rb_iter_next_ptr :: #force_inline proc "contextless" (it: ^Ring_Buffer_Iter($T, $N)) -> (val: ^T, ok: bool) {
	if it.idx == it.rb.tail {
		return nil, false
	}
	val = &it.rb.buf[it.idx]
	it.idx = (it.idx + 1) % (N + 1)
	return val, true
}
