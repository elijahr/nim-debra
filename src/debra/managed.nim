## Managed memory wrapper for DEBRA-controlled ref objects.
##
## The Managed[T] type wraps a ref object and prevents Nim's GC
## from collecting it until explicitly retired through DEBRA.
##
## ## Pitfalls
##
## * `Atomic[Managed[ref T]]` falls back to spinlock-based atomics on
##   arc/orc/atomicArc. The fallback is gated behind
##   `-d:allowSpinlockManagedRef`. For atomic node pointers in a lock-free
##   data structure, prefer `Atomic[ptr T]` plus `retain` / `release` /
##   `releaseDestructor` from `debra/refptr`.
## * Under `--mm:refc`, destruction of a `Managed[T]` (via `retire` plus
##   reclamation) must occur on the same thread that called `managed`.
##   refc has thread-local GC heaps, so cross-thread `GC_unref` is undefined.
##   arc/orc use atomic shared refcounts and are not affected.
## * `managed obj` calls `GC_ref` once. The matching `GC_unref` happens during
##   reclamation, not at retire time. Do not call `GC_unref` manually on
##   the inner ref while it is in flight through DEBRA.
##
## ## See also
##
## * `debra/refptr`_ - lock-free `ptr T` alternative for atomic node storage.
## * `debra/typestates/retire`_ - the underlying typestate transition.
## * `retireAndReclaim`_ - one-shot pin + retire + reclaim convenience.

type Managed*[T] = distinct T
  ## A DEBRA-managed ref object.
  ##
  ## Created with `managed()`, which calls GC_ref to prevent
  ## automatic garbage collection. Must be retired through
  ## DEBRA for reclamation.

proc managed*[T: ref](obj: T): Managed[T] =
  ## Create a managed ref object.
  ##
  ## WARNING: Atomic[Managed[ref T]] uses spinlocks on arc/orc memory managers.
  ## For truly lock-free code, use pointer-based retire API with ptr T instead.
  ##
  ## To allow spinlock fallback, compile with: -d:allowSpinlockManagedRef
  ##
  ## Calls GC_ref to prevent garbage collection.
  ## Object will only be freed when retired and epoch-safe.
  ##
  ## See also: `inner`_, `retain`_ (for the lock-free `ptr T` pattern).
  runnableExamples("-d:allowSpinlockManagedRef"):
    type Node = ref object
      value: int

    let m = managed Node(value: 99)
    doAssert not m.isNil
    doAssert m.value == 99 # field access via the dot template
    doAssert m.inner.value == 99 # explicit unwrap to T
  when not defined(allowSpinlockManagedRef):
    when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
      {.
        error:
          "Managed[ref T] is not lock-free on arc/orc memory managers. " &
          "Atomic operations on ref types use spinlocks, defeating lock-free guarantees. " &
          "Use pointer-based retire(ptr, destructor) API instead, or " &
          "compile with -d:allowSpinlockManagedRef to explicitly allow spinlock fallback."
      .}
  GC_ref(obj)
  Managed[T](obj)

proc inner*[T](m: Managed[T]): T {.inline.} =
  ## Get the underlying ref.
  ##
  ## Use when you need to pass the ref to a proc that expects T.
  ##
  ## See also: `managed`_.
  runnableExamples("-d:allowSpinlockManagedRef"):
    type Node = ref object
      value: int

    let m = managed Node(value: 7)
    let r: Node = m.inner
    doAssert r.value == 7
  T(m)

proc isNil*[T](m: Managed[T]): bool {.inline.} =
  ## Check if the managed ref is nil.
  T(m).isNil

proc `==`*[T](a, b: Managed[T]): bool {.inline.} =
  ## Compare two managed refs for identity.
  T(a) == T(b)

proc `!=`*[T](a, b: Managed[T]): bool {.inline.} =
  ## Compare two managed refs for non-identity.
  T(a) != T(b)

template `.`*[T](m: Managed[T], field: untyped): untyped =
  ## Access fields of the underlying ref directly.
  ##
  ## Example:
  ##   let node = managed Node(value: 42)
  ##   echo node.value  # Accesses Node.value
  T(m).field

template `.=`*[T](m: var Managed[T], field: untyped, value: untyped): untyped =
  ## Set fields of the underlying ref directly.
  T(m).field = value
