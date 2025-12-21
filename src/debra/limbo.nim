## Limbo bag data structures for DEBRA+ retire queues.
##
## A limbo bag holds up to 64 retired objects. Bags are linked
## together forming a thread-local retire queue.

proc c_calloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

const LimboBagSize* = 64

type
  Destructor* = proc(p: pointer) {.nimcall.}

  RetiredObject* = object
    data*: pointer
    destructor*: Destructor

  LimboBag* = object
    objects*: array[LimboBagSize, RetiredObject]
    count*: int
    epoch*: uint64
    next*: ptr LimboBag

proc allocLimboBag*(): ptr LimboBag =
  ## Allocate a new empty limbo bag.
  result = cast[ptr LimboBag](c_calloc(1, csize_t(sizeof(LimboBag))))

proc freeLimboBag*(bag: ptr LimboBag) =
  ## Free a limbo bag (does NOT call destructors).
  c_free(bag)

proc reclaimBag*(bag: ptr LimboBag) =
  ## Call destructors for all objects in bag, then free bag.
  for i in 0 ..< bag.count:
    let obj = bag.objects[i]
    if obj.destructor != nil:
      obj.destructor(obj.data)
  freeLimboBag(bag)

proc unreffer*[T: ref](): Destructor =
  ## Generate a destructor that calls GC_unref for type T.
  ##
  ## Used internally by retire() to create type-specific
  ## destructors for Managed[T] objects.
  result = proc(p: pointer) {.nimcall.} =
    GC_unref(cast[T](p))
