## Compile-fail test: retireOnCAS must reject a non-pointer element type.
##
## `pinned_scope.nim` constrains `retireOnCAS`'s generic `T` to
## `ptr | pointer`. Only raw pointer types are sound: the displaced value is
## `cast[pointer]` and reclaimed via `dtor`, so a GC-managed `ref` (or any
## non-pointer type) must be rejected at compile time rather than only by
## documentation. A `ref` element type is independently rejected earlier by
## `Atomic[ref T]`, so this case exercises the `retireOnCAS` constraint
## directly with a non-pointer scalar (`int`) that `Atomic` itself accepts.
## The runner verifies the constraint by invoking `nim c` and asserting the
## constraint-failure substring appears in the compiler's error output.

import debra
import debra/atomics

proc dtor(p: pointer) {.nimcall.} =
  dealloc(p)

proc main() =
  var manager = initDebraManager[4]()
  setGlobalManager(addr manager)
  let handle = registerThread(manager)

  var slot: Atomic[int] # non-pointer element type: violates T: ptr | pointer
  var scope = pinScope(unpinned(handle))
  var exp = slot.load(moAcquire)
  # T inferred as `int`, violating the `T: ptr | pointer` constraint.
  discard scope.retireOnCAS(slot, exp, 42, dtor)

main()
