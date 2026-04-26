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

# ---------------------------------------------------------------------------
# Batched retire/reclaim API (see docs/design/2026-04-25-batched-retire-reclaim.md)
# ---------------------------------------------------------------------------

proc retire*[MT: static int](
    pin: var RetireReady[MT], p: pointer, destructor: Destructor
) =
  ## Retire `p` inside an existing pinned epoch held by `pin`.
  ##
  ## Wraps the sink-form `retire` from typestates/retire.nim so the caller
  ## can chain `pin.retire(...)` repeatedly inside a `withPin` body without
  ## manually rebuilding `RetireReady` from `Retired`.
  let retired = retire(move(pin), p, destructor)
  pin = retireReadyFromRetired(retired)

proc retire*[T: ref, MT: static int](
    pin: var RetireReady[MT], obj: Managed[T]
) =
  ## Retire a `Managed[ref T]` inside an existing pinned epoch held by `pin`.
  let retired = retire(move(pin), obj)
  pin = retireReadyFromRetired(retired)

template withPin*[MT: static int](
    handle: ThreadHandle[MT], body: untyped
) =
  ## Pin the calling thread, run `body`, unpin on exit (including raises).
  ##
  ## Injects `pin` as a `var RetireReady[MT]`. Body may call
  ## `pin.retire(p, dtor)` zero or more times.
  block:
    let h = handle
    let pinnedGuard = unpinned(h).pin()
    var pin {.inject.} = retireReady(pinnedGuard)
    try:
      body
    finally:
      let ctx = RetireContext[MT](pin)
      let p = Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
      discard p.unpin()

template withPin*[MT: static int](
    handle: ThreadHandle[MT], name, body: untyped
) =
  ## `withPin` variant that injects a caller-supplied identifier `name`
  ## (instead of the default `pin`). Use to disambiguate nested handles
  ## across multiple managers.
  block:
    let h = handle
    let pinnedGuard = unpinned(h).pin()
    var name {.inject.} = retireReady(pinnedGuard)
    try:
      body
    finally:
      let ctx = RetireContext[MT](name)
      let p = Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
      discard p.unpin()

proc reclaimNow*[MT: static int](manager: var DebraManager[MT]): int =
  ## Run one reclamation pass. Returns the number of objects reclaimed,
  ## or 0 if no epoch is currently safe to reclaim.
  ##
  ## Pinning is not required: reclamation only inspects per-thread epochs.
  ## Named distinctly from the typestate-level `tryReclaim` on `ReclaimReady`
  ## (`reclaim.nim`) to avoid reader confusion.
  let op = reclaimStart(addr manager).loadEpochs().checkSafe()
  if op.kind == rReclaimReady:
    op.reclaimready.tryReclaim()
  else:
    0

proc retireAndReclaim*[MT: static int](
    handle: ThreadHandle[MT], p: pointer, destructor: Destructor, eager: bool = true
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
  let pinnedAgain =
    Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
  discard pinnedAgain.unpin()

  # Optional eager reclamation
  if eager:
    let reclaim = reclaimStart(handle.manager).loadEpochs().checkSafe()
    if reclaim.kind == rReclaimReady:
      discard reclaim.reclaimready.tryReclaim()

proc retireAndReclaim*[T: ref, MT: static int](
    handle: ThreadHandle[MT], obj: Managed[T], eager: bool = true
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
  let pinnedAgain =
    Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
  discard pinnedAgain.unpin()

  # Optional eager reclamation
  if eager:
    let reclaim = reclaimStart(handle.manager).loadEpochs().checkSafe()
    if reclaim.kind == rReclaimReady:
      discard reclaim.reclaimready.tryReclaim()
