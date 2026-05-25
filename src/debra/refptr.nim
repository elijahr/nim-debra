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
## ## Naming convention
##
## This module is the **object-lifetime** layer: `retain` / `release` /
## `releaseDestructor` operate on a single object's GC refcount and have no
## awareness of epochs, threads, or limbo bags.
##
## The **manager-level** layer in `debra/convenience` and
## `debra/typestates/{retire,reclaim}` uses different verbs (`retire`,
## `reclaim`, `tryReclaim`, `retireAndReclaim`) because it operates on the
## epoch-based reclamation pipeline: deferring destruction until no thread
## can observe the object. The two layers compose: a `releaseDestructor[T]()`
## value is the destructor handed to `pin.retire(p, dtor)` so that `release`
## runs at safe-epoch reclamation time. The verbs differ because the layers
## differ; do not expect `release` and `reclaim` (or `retain` and `retire`)
## to be synonyms.
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

proc releaseDestructorImpl[T](p: pointer) {.nimcall, raises: [].} =
  # Top-level per-`T` instantiation backing `releaseDestructor[T]()`.
  # Lives at module scope so the compiler emits a plain procedure (no
  # captured environment, no per-call heap allocation). Retire sites that
  # repeatedly call `releaseDestructor[T]()` therefore share a single
  # function pointer per `T` and incur no per-call closure construction.
  #
  # `T` may be supplied as either the object type (`NodeObj`) or the ref
  # alias (`Node = ref NodeObj`). `retain` is parameterised on the ref
  # form, so users naturally have both names in scope; without the `when`
  # guard, `releaseDestructor[Node]()` would silently `cast[ref ref
  # NodeObj]` and the resulting `GC_unref` would decrement the wrong
  # cell. Branching on `T is ref` makes either spelling correct, matching
  # the symmetry users expect with `retain[T: ref](obj: T)`.
  if p != nil:
    when T is ref:
      GC_unref(cast[T](p))
    else:
      GC_unref(cast[ref T](p))

proc releaseDestructor*[T](): Destructor {.inline.} =
  ## Return the `Destructor` (the type DEBRA's `retire` accepts) that
  ## releases a typed pointer obtained from `retain[ref T]`. Hand the
  ## result to `pin.retire(rawPtr, releaseDestructor[T]())`.
  ##
  ## `T` may be supplied as either the object type or its `ref` alias —
  ## `releaseDestructor[NodeObj]()` and `releaseDestructor[Node]()`
  ## (where `Node = ref NodeObj`) both produce a destructor that
  ## decrements the correct GC cell. The implementation branches on
  ## `T is ref` to avoid a silent `cast[ref ref T]` on the alias spelling.
  ## The object-type spelling is canonical (it matches what `retain`
  ## returns: `ptr typeof(obj[])`); the alias spelling exists for
  ## symmetry with `retain[T: ref](obj: T)`.
  ##
  ## The returned `Destructor` is a plain `nimcall` procedure address with
  ## no captured environment, so each `T` instantiation produces one
  ## function pointer that is reused across calls. Calling
  ## `releaseDestructor[T]()` repeatedly does not allocate. Note that
  ## `releaseDestructor[NodeObj]` and `releaseDestructor[Node]`
  ## instantiate to *different* function pointers — same behaviour, two
  ## entries in the binary. Pick one form per call site.
  ##
  ## See also: `retain`_, `release`_.
  runnableExamples:
    import debra
    type
      NodeObj = object
        value: int

      Node = ref NodeObj

    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    # Object-type spelling — canonical, matches what `retain` returns.
    # `releaseDestructor[T]()` returns the same proc address each call;
    # passing it inline costs no allocation.
    block:
      var scope = pinScope(unpinned(handle))
      var ready = retireReady(scope.state)
      let raw = retain(Node(value: 1))
      ready.retire(raw, releaseDestructor[NodeObj]())
  releaseDestructorImpl[T]
