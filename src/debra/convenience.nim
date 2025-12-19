## High-level convenience API for common DEBRA patterns.
##
## These procs compose the low-level typestate API for frequent use cases.
## For fine-grained control or batching, use the typestate API directly.

import ./types
import ./limbo
import ./managed
import ./typestates/guard
import ./typestates/retire
import ./typestates/reclaim

proc retireAndReclaim*[MT: static int](
  handle: ThreadHandle[MT],
  p: pointer,
  destructor: Destructor,
  eager: bool = true
) =
  ## Retire a pointer and optionally attempt immediate reclamation.
  ##
  ## This convenience wrapper:
  ## 1. Pins the current thread
  ## 2. Retires the pointer with the given destructor
  ## 3. Unpins the thread
  ## 4. If eager=true (default), attempts to reclaim retired objects
  ##
  ## For batching multiple retirements before reclaiming, use the
  ## low-level typestate API directly or call with eager=false.
  ##
  ## Example:
  ##   proc destroyNode(p: pointer) {.nimcall.} =
  ##     dealloc(p)
  ##
  ##   let node = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
  ##   retireAndReclaim(handle, node, destroyNode)

  # Pin, retire, unpin
  let pinned = unpinned(handle).pin()
  let ready = retireReady(pinned)
  let retired = ready.retire(p, destructor)

  # Convert Retired back to Pinned for unpinning
  let ctx = RetireContext[MT](retired)
  let pinnedAgain = Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
  discard pinnedAgain.unpin()

  # Optional eager reclamation
  if eager:
    let reclaim = reclaimStart(handle.manager).loadEpochs().checkSafe()
    if reclaim.kind == rReclaimReady:
      discard reclaim.reclaimready.tryReclaim()

proc retireAndReclaim*[T: ref, MT: static int](
  handle: ThreadHandle[MT],
  obj: Managed[T],
  eager: bool = true
) =
  ## Retire a Managed[ref T] and optionally attempt immediate reclamation.
  ##
  ## WARNING: Managed[ref T] uses spinlock-based atomics on arc/orc memory
  ## managers, defeating lock-free guarantees. Prefer pointer-based
  ## retire(ptr, destructor) for lock-free code.
  ##
  ## This convenience wrapper:
  ## 1. Pins the current thread
  ## 2. Retires the managed object
  ## 3. Unpins the thread
  ## 4. If eager=true (default), attempts to reclaim retired objects
  ##
  ## Example:
  ##   type Node = ref object
  ##     value: int
  ##
  ##   let node = managed Node(value: 42)
  ##   retireAndReclaim(handle, node)

  # Pin, retire, unpin
  let pinned = unpinned(handle).pin()
  let ready = retireReady(pinned)
  let retired = ready.retire(obj)

  # Convert Retired back to Pinned for unpinning
  let ctx = RetireContext[MT](retired)
  let pinnedAgain = Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
  discard pinnedAgain.unpin()

  # Optional eager reclamation
  if eager:
    let reclaim = reclaimStart(handle.manager).loadEpochs().checkSafe()
    if reclaim.kind == rReclaimReady:
      discard reclaim.reclaimready.tryReclaim()
