// Context layout assumed here (checked against Context in context.odin
// via #assert): rbx, rsp, rbp, r12, r13, r14, r15, rflags: u64 (8 bytes
// each), rip: uintptr (8 bytes) -- 9 fields * 8 bytes, no padding.
//
// Resuming always goes through `ret`, never through `ctx.rip` directly:
// the saved rsp already points at whatever `[rsp]` held at save time (the
// real return address pushed by the caller's `call`), so restoring rsp
// and doing `ret` lands exactly back where execution left off. A freshly
// initialized fiber fakes this by having its stack's top word hold the
// entry function pointer, so the first `ret` jumps straight into it.
.intel_syntax noprefix
.text

// str_ctx(ctx)
//
// Saves the caller's preserved registers into ctx and returns normally. The
// return address is copied out of [rsp] into ctx.rip because resuming this
// context later goes through `ret`, not through a direct jump to rip.
.globl str_ctx
.type str_ctx,@function
str_ctx:
    mov [rdi+0],  rbx
    mov [rdi+8],  rsp
    mov [rdi+16], rbp
    mov [rdi+24], r12
    mov [rdi+32], r13
    mov [rdi+40], r14
    mov [rdi+48], r15
    pushfq
    pop  rax
    mov [rdi+56], rax
    mov rax, [rsp]
    mov [rdi+64], rax
    ret

// ld_ctx(ctx)
//
// Restores ctx and resumes it. This is a one-way jump: whatever context calls
// ld_ctx is not saved, so it must not expect to continue afterwards.
.globl ld_ctx
.type ld_ctx,@function
ld_ctx:
    mov rsp, [rdi+8]
    mov rbx, [rdi+0]
    mov rbp, [rdi+16]
    mov r12, [rdi+24]
    mov r13, [rdi+32]
    mov r14, [rdi+40]
    mov r15, [rdi+48]
    mov rax, [rdi+56]
    push rax
    popfq
    ret

// switch_ctx(old_ctx, new_ctx)
//
// Saves the current context into old_ctx, then restores and resumes new_ctx.
// When old_ctx is resumed later, execution continues just after this call.
.globl switch_ctx
.type switch_ctx,@function
switch_ctx:
    mov [rdi+0],  rbx
    mov [rdi+8],  rsp
    mov [rdi+16], rbp
    mov [rdi+24], r12
    mov [rdi+32], r13
    mov [rdi+40], r14
    mov [rdi+48], r15
    pushfq
    pop  rax
    mov [rdi+56], rax
    mov rax, [rsp]
    mov [rdi+64], rax

    mov rsp, [rsi+8]
    mov rbx, [rsi+0]
    mov rbp, [rsi+16]
    mov r12, [rsi+24]
    mov r13, [rsi+32]
    mov r14, [rsi+40]
    mov r15, [rsi+48]
    mov rax, [rsi+56]
    push rax
    popfq
    ret
