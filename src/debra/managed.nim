## Managed memory wrapper for DEBRA-controlled ref objects.
##
## The Managed[T] type wraps a ref object and prevents Nim's GC
## from collecting it until explicitly retired through DEBRA.

type
  Managed*[T] = distinct T
    ## A DEBRA-managed ref object.
    ##
    ## Created with `managed()`, which calls GC_ref to prevent
    ## automatic garbage collection. Must be retired through
    ## DEBRA for reclamation.

proc managed*[T: ref](obj: T): Managed[T] =
  ## Create a managed ref object.
  ##
  ## Calls GC_ref to prevent garbage collection.
  ## Object will only be freed when retired and epoch-safe.
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
