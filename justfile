set shell := ["bash", "-euo", "pipefail", "-c"]

asm:
    as context_switch.s -o context_switch.o

check: asm
    odin check . -vet -no-entry-point
    odin check utils -vet -no-entry-point
    odin check bench -vet
    odin check stress -vet

test: asm
    odin test . -vet -define:ODIN_TEST_THREADS=1
    odin test utils -vet

stress: asm
    odin test . -vet -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=test_runtime_limits_under_stress

limits: asm
    @mkdir -p build
    odin build stress -out:build/limits -o:speed -microarch:native

test-asan: asm
    odin test . -vet -define:ODIN_TEST_THREADS=1 -sanitize:address
    odin test utils -vet -sanitize:address

bench: asm
    @mkdir -p build
    odin build bench -out:build/bench -o:speed -microarch:native
    ./build/bench

clean:
    rm -f context_switch.o
