## Managed memory wrapper for DEBRA-controlled ref objects.
##
## The Managed[T] type wraps a ref object and prevents Nim's GC
## from collecting it until explicitly retired through DEBRA.

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
