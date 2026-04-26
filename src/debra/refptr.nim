## Bridge `ref` types into `Atomic[ptr T]` storage with explicit GC tracking.
##
## ## Why
##
## `Atomic[ref T]` falls back to spinlock-based atomics on arc/orc, which
## defeats lock-free guarantees. For atomic pointer storage in lock-free
## data structures, convert the `ref` into a raw `ptr T`, increment the GC
## ref count manually so the object survives, and decrement it from the
## DEBRA destructor at retire-reclaim time.
##
## ## API
##
## * `retain(obj)` -> `ptr T`: GC_ref + cast.
## * `release(p)`: GC_unref the pointer (nil-safe).
## * `releaseDestructor[T]()` -> `Destructor`: factory that returns a
##   `Destructor` releasing a `ptr T`. Pass to `it.retire(p, releaseDestructor[T]())`.
##
## Each `retain` MUST be paired with exactly one `release` (typically via
## `releaseDestructor[T]()` handed to `pin.retire`). Double-release will
## free the underlying object early.
##
## ## Pitfalls
##
## * Every `retain` must be paired with exactly one `release`. Double-release
##   will free the object early; missing release leaks the underlying GC cell.
## * `release` is nil-safe (no-op on `nil`). Passing `nil` to `retain` is a
##   programmer error and will likely crash inside `GC_ref`.
## * Under `--mm:refc`, `release` (or any reclamation that runs the destructor
##   produced by `releaseDestructor[T]()`) must occur on the same thread that
##   called `retain`. refc has thread-local GC heaps; cross-thread `GC_unref`
##   is undefined and crashes inside `decRef`. arc/orc use atomic shared
##   refcounts and are not affected. See `examples/reclamation_background.nim`
##   for the full investigation.
##
## ## See also
##
## * `debra/typestates/retire`_ - underlying `pin.retire(p, dtor)` transition.

import ./limbo

proc retain*[T: ref](obj: T): ptr typeof(obj[]) {.inline.} =
  ## Increment the GC ref count and return a raw pointer suitable for
  ## atomic storage. The caller owns the resulting pointer's reference
  ## count; pair every `retain` with exactly one `release` (usually via
  ## `releaseDestructor[T]()` handed to `pin.retire`).
  ##
  ## Passing nil is a programmer error and will likely crash inside
  ## `GC_ref`. The result is never nil.
  ##
  ## See also: `release`_, `releaseDestructor`_.
  runnableExamples:
    type Node = ref object
      value: int

    let r = Node(value: 5)
    let p = retain(r)
    doAssert p != nil
    doAssert p.value == 5
    release(p) # balance the retain
  GC_ref(obj)
  cast[ptr typeof(obj[])](obj)

proc release*[T](p: ptr T) {.inline.} =
  ## Decrement the GC ref count for a pointer obtained via `retain`.
  ## Safe to call on `nil` (no-op).
  ##
  ## Note: takes `ptr T` (the value type), matching what `retain` returns.
  ##
  ## See also: `retain`_, `releaseDestructor`_.
  runnableExamples:
    type Node = ref object
      value: int

    var p: ptr Node = nil
    release(p) # nil-safe no-op
    let r = Node(value: 1)
    let q = retain(r)
    release(q) # pairs the retain
  if p != nil:
    GC_unref(cast[ref T](p))

proc releaseDestructorImpl[T](p: pointer) {.nimcall.} =
  # Top-level per-`T` instantiation backing `releaseDestructor[T]()`.
  # Lives at module scope so the compiler emits a plain procedure (no
  # captured environment, no per-call heap allocation). Retire sites that
  # repeatedly call `releaseDestructor[T]()` therefore share a single
  # function pointer per `T` and incur no per-call closure construction.
  if p != nil:
    GC_unref(cast[ref T](p))

proc releaseDestructor*[T](): Destructor {.inline.} =
  ## Return the `Destructor` (the type DEBRA's `retire` accepts) that
  ## releases a typed pointer obtained from `retain[ref T]`. Hand the
  ## result to `pin.retire(rawPtr, releaseDestructor[T]())`.
  ##
  ## The returned `Destructor` is a plain `nimcall` procedure address with
  ## no captured environment, so each `T` instantiation produces one
  ## function pointer that is reused across calls. Calling
  ## `releaseDestructor[T]()` repeatedly does not allocate.
  ##
  ## See also: `retain`_, `release`_.
  runnableExamples:
    import debra
    type Node = ref object
      value: int

    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    # `releaseDestructor[T]()` returns the same proc address each call;
    # passing it inline costs no allocation.
    withPin(handle):
      let raw = retain(Node(value: 1))
      it.retire(raw, releaseDestructor[Node]())
  releaseDestructorImpl[T]
