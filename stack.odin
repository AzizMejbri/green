package green

import "core:sys/posix"
import "core:fmt"

// Operating-system page size assumed by the stack allocator.
PAGE_SIZE: uint: 4096

// Default amount of usable stack given to a task when spawn/sched_spawn is
// not given an explicit stack_size. Set by rt_init/sched_init from
// Rt_Config.default_stack_size -- not a constant, specifically so that
// override takes effect: every stack_size: uint = DEFAULT_STACK default
// parameter below is re-read at each call site, not baked in at compile
// time (verified empirically: a mutable global used as a default parameter
// value is re-evaluated per call, unlike a `::` constant).
DEFAULT_STACK: uint = 8 * 1024

// Extra page placed below a task's stack. It is mapped without any permissions,
// so an overflow hits a fault instead of quietly corrupting nearby memory.
GUARD_SIZE: uint: PAGE_SIZE

// Stack describes the usable part of a task's stack.
//
// top points one byte past the end of the usable region, which is where the
// stack starts growing downward. cap is the usable size in bytes; the guard
// page is not included.
Stack :: struct {
	top: [^]byte,
	cap: uint,
}

// stack_alloc reserves a new task stack with a guard page below it.
//
// size is rounded up to a whole number of pages. The returned Stack owns an
// mmap region and must be released with stack_free. Returns ok = false if the
// operating system cannot map or protect the memory.
stack_alloc :: proc (size: uint = DEFAULT_STACK) -> (st: Stack, ok: bool) {
	rounded := (size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
	total   := rounded + GUARD_SIZE

	// Reserve the usable stack and the guard page in one mapping.
	ptr := posix.mmap(nil, total, {.READ, .WRITE}, {.ANONYMOUS, .PRIVATE})
	if ptr == posix.MAP_FAILED {
		fmt.println("Mmap failed at stack_alloc()")
		return {}, false
	}

	// Remove all access from the lowest page so a stack overflow faults
	// immediately instead of overwriting whatever lives below the stack.
	if posix.mprotect(ptr, GUARD_SIZE, {}) == .FAIL {
		posix.munmap(ptr, total)
		fmt.eprintln("mprotect() syscall failed in stack_alloc()")
		return {}, false
	}

	top := ([^]byte)(ptr)[total:]

	return Stack{
		top = top,
		cap = rounded,
	}, true
}

// stack_free releases a stack created by stack_alloc.
//
// The stack must not be in use when this is called. A zero Stack is ignored, so
// cleanup is safe even after a failed allocation.
stack_free :: proc(s: Stack) {
	if s.top == nil { return }

	// top is base + cap + guard size. Subtracting both gives back the exact
	// address returned by mmap, which is required for munmap.
	orig := rawptr(([^]byte)(s.top)[-(s.cap + GUARD_SIZE):])
	posix.munmap(orig, s.cap + GUARD_SIZE)
}
