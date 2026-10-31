package green

// Context is a snapshot of the CPU state needed to pause and later resume a
// task.
//
// Only registers that the System V ABI requires a function to preserve are
// stored. Everything else belongs to the function call that was interrupted and
// is already handled by the normal calling convention.
Context :: struct {
	rbx, rsp, rbp, r12, r13, r14, r15: u64,
	rflags: u64,
	rip: uintptr,
}

// context_switch.s addresses these fields by hardcoded byte offset. These
// assertions turn any future field reordering or padding change into a compile
// error instead of a mysterious crash.
#assert(offset_of(Context, rbx)    == 0)
#assert(offset_of(Context, rsp)    == 8)
#assert(offset_of(Context, rbp)    == 16)
#assert(offset_of(Context, r12)    == 24)
#assert(offset_of(Context, r13)    == 32)
#assert(offset_of(Context, r14)    == 40)
#assert(offset_of(Context, r15)    == 48)
#assert(offset_of(Context, rflags) == 56)
#assert(offset_of(Context, rip)    == 64)
#assert(size_of(Context) == 72)

// context_switch.o is assembled from context_switch.s by the build recipe.
foreign import libcontext_switch "context_switch.o"

foreign libcontext_switch {
	// ld_ctx restores ctx and jumps into it. It never returns to the caller.
	ld_ctx :: proc "c" (ctx: ^Context) -> ! ---

	// str_ctx saves the current execution state into ctx and returns normally.
	str_ctx :: proc "c" (ctx: ^Context) ---

	// switch_ctx saves the current execution state into old_ctx, then restores
	// and resumes new_ctx.
	switch_ctx :: proc "c" (old_ctx, new_ctx: ^Context) ---
}

// context_init prepares a brand-new Context so that resuming it starts entry on
// stack.
//
// The assembly resumes by executing `ret`. A newly created task therefore needs
// a return address on top of its stack, just as if a call instruction had just
// pushed it. The slot is 16-byte aligned so entry starts with the stack layout
// the System V ABI expects.
//
// In normal use entry is fiber_trampoline, which installs the task's Odin
// context and calls the user's task body. This function is also used by the
// context-switch benchmark to enter a raw test routine.
context_init :: proc(ctx: ^Context, stack: Stack, entry: rawptr) {
	entry_addr := uintptr(entry)

	slot := uintptr(stack.top) - 8
	slot &= ~uintptr(0xF)
	(cast(^uintptr)slot)^ = entry_addr

	ctx^ = {}
	ctx.rsp = u64(slot)
	ctx.rip = entry_addr
}
