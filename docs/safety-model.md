# Safety Model

nim-debra is built for lock-free data structures. The library actively rules
out the most common spinlock-fallback footgun in Nim's `std/atomics` — atomic
storage of `ref T` — and ships a small `retain` / `release` bridge so that
`ref` values can still live inside `Atomic[ptr T]` slots without losing the
lock-free guarantee.

This document explains the underlying constraints, the recipes for using the
bridge correctly, and the testing matrix used to keep them honest.

## The one rule

`Atomic[ref T]` does not compile under `--mm:arc` or `--mm:orc`. `Atomic[T]`
also rejects any `T` whose width is not `__atomic_always_lock_free` on the
target. Use `Atomic[ptr T]` together with `retain` and `releaseDestructor`
when you need to put a `ref` into an atomic slot.

The error messages from `debra/atomics` (see [`src/debra/atomics.nim`](https://github.com/elijahr/nim-debra/blob/main/src/debra/atomics.nim))
point you at the bridge directly.

## Why `Atomic[ref T]` is rejected

Nim's `std/atomics` silently spinlocks any `T` that is not `Trivial`. `ref T`
falls into that bucket on arc/orc, so what looks like a lock-free CAS is
quietly using a per-object spinlock under the hood. That defeats the whole
point of an EBR library: a thread holding a pinned epoch can be blocked on
that spinlock by an unrelated thread, which is the kind of priority inversion
EBR is supposed to make impossible.

`debra/atomics` wraps GCC/Clang `__atomic_*` builtins directly. It refuses
non-trivially-copyable `T` at compile time, refuses `ref T` at compile time,
and emits a `__atomic_always_lock_free` static assertion in the C output so
that any width which would secretly fall back to a libatomic call also fails
to compile. The full design rationale lives in
[`docs/design/2026-04-25-custom-atomics.md`](design/2026-04-25-custom-atomics.md).

If you genuinely need a non-lock-free atomic for some reason — testing,
prototyping, an unusual target — you can pass `-d:debraAllowNonLockFreeAtomics`
to silence the C-level assertion. The Nim-level checks against `ref T` and
`supportsCopyMem` cannot be bypassed.

## The `retain` / `release` bridge

`retain(obj)` increments the GC ref count and casts to `ptr typeof(obj[])`,
yielding a value safe to store in `Atomic[ptr T]`. The matching `release`
decrements the ref count. The library ships a `releaseDestructor[T]()`
factory that returns a `Destructor` (the type `retire` accepts), so the most
common pattern looks like this:

```nim
let raw = retain Node(value: 1)
slot.store(raw, moRelease)
# ...later, after we swap a new value into the slot...
withPin(handle):
  it.retire(cast[pointer](raw), releaseDestructor[Node]())
```

The destructor runs once the epoch is safe, and that is the moment `release`
fires. Each `retain` must be balanced by exactly one `release`. Double-release
frees the object early; missing release leaks the underlying GC cell.

## Memory manager notes

The CI matrix exercises the library under `--mm:arc`, `--mm:orc`,
`--mm:atomicArc`, and `--mm:refc`. Three of those use shared atomic refcounts
and behave identically as far as the bridge is concerned.

`--mm:refc` is the exception. refc keeps the GC heap thread-local, so a
`GC_unref` issued from a thread other than the one that called `GC_ref` is
undefined behaviour and crashes inside `decRef`. Concretely: every `retain`
on thread A must be balanced by a `release` on thread A. If your design hands
retired pointers off to a background reclaim thread, that pattern works on
arc/orc/atomicArc but not on refc.

`examples/reclamation_background.nim` runs into exactly this issue and skips
itself with a clear diagnostic when compiled with `--mm:refc`. If your
project supports refc, run reclamation on the same threads that retire.

## Toolchain support

`debra/atomics` wraps the `__atomic_*` family of builtins, so the supported C
backends are GCC, Clang, LLVM-GCC, and the Nintendo Switch toolchain. MSVC is
not supported; an MSVC backend would need its own intrinsic wrapper and is
not on the current roadmap.

## Testing recipes

The bug class this library exists to prevent — use-after-free between a
reader and a reclaimer — is the classic territory of TSAN, ASAN, and stress
tests. A good way to convince yourself the bridge is wired correctly in your
own data structure:

```bash
# Pick any of the supported memory managers.
nim c --threads:on --mm:orc -d:useMalloc \
  --debugger:native -t:-fsanitize=thread -l:-fsanitize=thread \
  your_test.nim
```

For ASAN, swap `thread` for `address`. The interesting tests run hundreds of
thousands of operations across several producer/consumer threads; short
single-threaded tests rarely surface the races the SC fences in `pin` /
`loadEpochs` are there to defeat. The lockfreequeues project bundles a set
of unbounded-queue stress tests that exercise nim-debra under exactly this
configuration; if you are designing your own EBR client, those tests are a
useful shape to copy.

## See also

- [Custom Atomics design doc](design/2026-04-25-custom-atomics.md) — full
  rationale for `debra/atomics`, alignment trap, fence encoding.
- [Concepts](guide/concepts.md) — a higher-level walk through DEBRA+ itself.
- [Pin / unpin](guide/pin-unpin.md) — the publication and subscription
  fences that make epoch tracking sound.
