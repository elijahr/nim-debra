# Limbo Bags, Proper Typestates, and Documentation Design

## Overview

This document describes the design for:
1. **Limbo bags** - Thread-local retire queues using linked batches (per DEBRA+ paper)
2. **Proper typestates** - Rewrite using nim-typestates library with `distinct` types and `{.transition.}` pragma
3. **lockfreequeues integration** - Replace EpochManager with nim-debra, add `=destroy` hooks
4. **MkDocs documentation** - Comprehensive docs like nim-typestates

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| EpochManager integration | Replace entirely | Eliminate duplication - debra is the epoch manager |
| Retire queue location | Thread-local in debra | Canonical DEBRA+ design, O(mn) bounded memory |
| Retired object representation | Type-erased with destructor callback | Simple API: `retire(ptr, destructor)` |
| Retire queue structure | Linked list of batches ("limbo bags") | Cache locality, batch reclaim, no realloc stalls |
| Queue `=destroy` behavior | Free active segments, leave retired to debra | Preserves epoch safety, simple implementation |

## Part 1: Limbo Bag Data Structures

### Core Types

```nim
const LimboBagSize* = 64

type
  Destructor* = proc(p: pointer) {.nimcall.}

  RetiredObject* = object
    data*: pointer
    destructor*: Destructor

  LimboBag* = object
    objects*: array[LimboBagSize, RetiredObject]
    count*: int
    epoch*: uint64      # Epoch when this bag was created
    next*: ptr LimboBag # Links to older bags (toward tail)
```

### Thread-Local Retire Queue

Added to `ThreadState`:

```nim
type
  ThreadState*[MaxThreads: static int] = object
    # Existing fields...
    epoch* {.align: 8.}: Atomic[uint64]
    pinned* {.align: 8.}: Atomic[bool]
    neutralized* {.align: 8.}: Atomic[bool]
    osThreadId* {.align: 8.}: Atomic[Pid]

    # New limbo bag fields
    currentBag*: ptr LimboBag   # Bag currently being filled
    limboBagHead*: ptr LimboBag # Newest full bag (most recent epoch)
    limboBagTail*: ptr LimboBag # Oldest bag (reclaim from here)
```

### Limbo Bag Operations

```nim
proc allocLimboBag(): ptr LimboBag =
  result = cast[ptr LimboBag](c_calloc(1, csize_t(sizeof(LimboBag))))

proc freeLimboBag(bag: ptr LimboBag) =
  c_free(bag)

proc reclaimBag(bag: ptr LimboBag) =
  ## Call destructors for all objects in bag, then free bag.
  for i in 0..<bag.count:
    let obj = bag.objects[i]
    if obj.destructor != nil:
      obj.destructor(obj.data)
  freeLimboBag(bag)
```

## Part 2: Complete Typestate Architecture

All typestates use the nim-typestates library with proper `distinct` types.

### Typestate 1: SignalHandler

```nim
type
  SignalHandlerContext = object
    discard

  HandlerUninstalled* = distinct SignalHandlerContext
  HandlerInstalled* = distinct SignalHandlerContext

typestate SignalHandlerContext:
  states HandlerUninstalled, HandlerInstalled
  transitions:
    HandlerUninstalled -> HandlerInstalled

proc install(h: HandlerUninstalled): HandlerInstalled {.transition.} =
  # Install SIGUSR1 handler
  var sa: Sigaction
  sa.sa_handler = neutralizationHandler
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(QuiescentSignal, sa, nil)
  result = HandlerInstalled(h.SignalHandlerContext)
```

### Typestate 2: DebraManager

```nim
type
  ManagerContext*[MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]

  ManagerUninitialized*[MaxThreads: static int] = distinct ManagerContext[MaxThreads]
  ManagerReady*[MaxThreads: static int] = distinct ManagerContext[MaxThreads]
  ManagerShutdown*[MaxThreads: static int] = distinct ManagerContext[MaxThreads]

typestate ManagerContext:
  states ManagerUninitialized, ManagerReady, ManagerShutdown
  transitions:
    ManagerUninitialized -> ManagerReady
    ManagerReady -> ManagerShutdown

proc initialize[M: static int](m: ManagerUninitialized[M]): ManagerReady[M] {.transition.} =
  let mgr = m.ManagerContext.manager
  mgr.globalEpoch.store(1'u64, moRelaxed)
  mgr.activeThreadMask.store(0'u64, moRelaxed)
  # Initialize thread states...
  result = ManagerReady[M](m.ManagerContext)

proc shutdown[M: static int](m: ManagerReady[M]): ManagerShutdown[M] {.transition.} =
  # Reclaim all limbo bags, clean up
  result = ManagerShutdown[M](m.ManagerContext)
```

### Typestate 3: ThreadSlot

```nim
type
  SlotContext*[MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    slotIdx*: int

  SlotFree*[MaxThreads: static int] = distinct SlotContext[MaxThreads]
  SlotClaiming*[MaxThreads: static int] = distinct SlotContext[MaxThreads]
  SlotActive*[MaxThreads: static int] = distinct SlotContext[MaxThreads]
  SlotDraining*[MaxThreads: static int] = distinct SlotContext[MaxThreads]

typestate SlotContext:
  states SlotFree, SlotClaiming, SlotActive, SlotDraining
  transitions:
    SlotFree -> SlotClaiming
    SlotClaiming -> SlotActive | SlotFree as ClaimResult
    SlotActive -> SlotDraining
    SlotDraining -> SlotFree
```

### Typestate 4: Registration

```nim
type
  RegistrationContext*[MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]

  Unregistered*[MaxThreads: static int] = distinct RegistrationContext[MaxThreads]
  Registered*[MaxThreads: static int] = distinct RegistrationContext[MaxThreads]
  RegistrationFull*[MaxThreads: static int] = distinct RegistrationContext[MaxThreads]

typestate RegistrationContext:
  states Unregistered, Registered, RegistrationFull
  transitions:
    Unregistered -> Registered | RegistrationFull as RegistrationResult
  bridges:
    Registered -> EpochGuardContext.Unpinned

proc register[M: static int](u: Unregistered[M]): RegistrationResult[M] {.transition.} =
  # Find slot, CAS to claim, return Registered or RegistrationFull
  ...
```

### Typestate 5: EpochGuard (Pin/Unpin)

```nim
type
  EpochGuardContext*[MaxThreads: static int] = object
    handle*: ThreadHandle[MaxThreads]
    epoch*: uint64

  Unpinned*[MaxThreads: static int] = distinct EpochGuardContext[MaxThreads]
  Pinned*[MaxThreads: static int] = distinct EpochGuardContext[MaxThreads]
  Neutralized*[MaxThreads: static int] = distinct EpochGuardContext[MaxThreads]

typestate EpochGuardContext:
  states Unpinned, Pinned, Neutralized
  transitions:
    Unpinned -> Pinned
    Pinned -> Unpinned | Neutralized as UnpinResult
    Neutralized -> Unpinned
  bridges:
    Pinned -> RetireContext.RetireReady

proc pin[M: static int](u: Unpinned[M]): Pinned[M] {.transition.} =
  var ctx = u.EpochGuardContext
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  ctx.epoch = mgr.globalEpoch.load(moAcquire)
  mgr.threads[idx].neutralized.store(false, moRelease)
  mgr.threads[idx].epoch.store(ctx.epoch, moRelease)
  mgr.threads[idx].pinned.store(true, moRelease)

  result = Pinned[M](ctx)

proc unpin[M: static int](p: Pinned[M]): UnpinResult[M] {.transition.} =
  let ctx = p.EpochGuardContext
  let mgr = ctx.handle.manager
  let idx = ctx.handle.idx

  mgr.threads[idx].pinned.store(false, moRelease)

  if mgr.threads[idx].neutralized.load(moAcquire):
    UnpinResult[M] -> Neutralized[M](ctx)
  else:
    UnpinResult[M] -> Unpinned[M](ctx)

proc acknowledge[M: static int](n: Neutralized[M]): Unpinned[M] {.transition.} =
  let ctx = n.EpochGuardContext
  ctx.handle.manager.threads[ctx.handle.idx].neutralized.store(false, moRelease)
  result = Unpinned[M](ctx)
```

### Typestate 6: Retire

```nim
type
  RetireContext*[MaxThreads: static int] = object
    handle*: ThreadHandle[MaxThreads]
    epoch*: uint64

  RetireReady*[MaxThreads: static int] = distinct RetireContext[MaxThreads]
  Retired*[MaxThreads: static int] = distinct RetireContext[MaxThreads]

typestate RetireContext:
  states RetireReady, Retired
  transitions:
    RetireReady -> Retired

proc retire[M: static int](
  r: RetireReady[M],
  data: pointer,
  destructor: Destructor
): Retired[M] {.transition.} =
  let ctx = r.RetireContext
  let state = addr ctx.handle.manager.threads[ctx.handle.idx]

  # Ensure we have a bag with space
  if state.currentBag == nil or state.currentBag.count >= LimboBagSize:
    let newBag = allocLimboBag()
    newBag.epoch = ctx.epoch
    newBag.next = state.currentBag
    if state.limboBagTail == nil:
      state.limboBagTail = newBag
    state.currentBag = newBag

  # Add object to bag
  let bag = state.currentBag
  bag.objects[bag.count] = RetiredObject(data: data, destructor: destructor)
  inc bag.count

  result = Retired[M](ctx)
```

### Typestate 7: LimboBag

```nim
type
  BagContext* = object
    bag*: ptr LimboBag

  BagEmpty* = distinct BagContext
  BagFilling* = distinct BagContext
  BagFull* = distinct BagContext
  BagReclaimable* = distinct BagContext
  BagReclaimed* = distinct BagContext

typestate BagContext:
  states BagEmpty, BagFilling, BagFull, BagReclaimable, BagReclaimed
  transitions:
    BagEmpty -> BagFilling
    BagFilling -> BagFull
    BagFull -> BagReclaimable
    BagReclaimable -> BagReclaimed
```

### Typestate 8: Reclaim

```nim
type
  ReclaimContext*[MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    globalEpoch*: uint64
    safeEpoch*: uint64

  ReclaimStart*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  EpochsLoaded*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  ReclaimReady*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]
  ReclaimBlocked*[MaxThreads: static int] = distinct ReclaimContext[MaxThreads]

typestate ReclaimContext:
  states ReclaimStart, EpochsLoaded, ReclaimReady, ReclaimBlocked
  transitions:
    ReclaimStart -> EpochsLoaded
    EpochsLoaded -> ReclaimReady | ReclaimBlocked as ReclaimCheck

proc loadEpochs[M: static int](s: ReclaimStart[M]): EpochsLoaded[M] {.transition.} =
  var ctx = s.ReclaimContext
  ctx.globalEpoch = ctx.manager.globalEpoch.load(moAcquire)
  ctx.safeEpoch = ctx.globalEpoch

  for i in 0..<M:
    if ctx.manager.threads[i].pinned.load(moAcquire):
      let threadEpoch = ctx.manager.threads[i].epoch.load(moAcquire)
      if threadEpoch < ctx.safeEpoch:
        ctx.safeEpoch = threadEpoch

  result = EpochsLoaded[M](ctx)

proc checkSafe[M: static int](e: EpochsLoaded[M]): ReclaimCheck[M] {.transition.} =
  let ctx = e.ReclaimContext
  if ctx.safeEpoch > 1:
    ReclaimCheck[M] -> ReclaimReady[M](ctx)
  else:
    ReclaimCheck[M] -> ReclaimBlocked[M](ctx)
```

### Typestate 9: EpochAdvance

```nim
type
  AdvanceContext*[MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    oldEpoch*: uint64
    newEpoch*: uint64

  EpochCurrent*[MaxThreads: static int] = distinct AdvanceContext[MaxThreads]
  EpochAdvancing*[MaxThreads: static int] = distinct AdvanceContext[MaxThreads]
  EpochAdvanced*[MaxThreads: static int] = distinct AdvanceContext[MaxThreads]

typestate AdvanceContext:
  states EpochCurrent, EpochAdvancing, EpochAdvanced
  transitions:
    EpochCurrent -> EpochAdvancing
    EpochAdvancing -> EpochAdvanced

proc beginAdvance[M: static int](c: EpochCurrent[M]): EpochAdvancing[M] {.transition.} =
  var ctx = c.AdvanceContext
  ctx.oldEpoch = ctx.manager.globalEpoch.load(moAcquire)
  result = EpochAdvancing[M](ctx)

proc commitAdvance[M: static int](a: EpochAdvancing[M]): EpochAdvanced[M] {.transition.} =
  var ctx = a.AdvanceContext
  ctx.newEpoch = ctx.manager.globalEpoch.fetchAdd(1'u64, moRelease) + 1
  result = EpochAdvanced[M](ctx)
```

### Typestate 10: Neutralize

```nim
type
  NeutralizeContext*[MaxThreads: static int] = object
    manager*: ptr DebraManager[MaxThreads]
    threshold*: uint64
    signalsSent*: int

  ScanStart*[MaxThreads: static int] = distinct NeutralizeContext[MaxThreads]
  Scanning*[MaxThreads: static int] = distinct NeutralizeContext[MaxThreads]
  ScanComplete*[MaxThreads: static int] = distinct NeutralizeContext[MaxThreads]

typestate NeutralizeContext:
  states ScanStart, Scanning, ScanComplete
  transitions:
    ScanStart -> Scanning
    Scanning -> ScanComplete

proc beginScan[M: static int](
  s: ScanStart[M],
  epochsBeforeNeutralize: uint64 = 2
): Scanning[M] {.transition.} =
  var ctx = s.NeutralizeContext
  let globalEpoch = ctx.manager.globalEpoch.load(moAcquire)
  ctx.threshold = if globalEpoch > epochsBeforeNeutralize:
    globalEpoch - epochsBeforeNeutralize
  else:
    0'u64
  ctx.signalsSent = 0
  result = Scanning[M](ctx)

proc scanAndSignal[M: static int](s: Scanning[M]): ScanComplete[M] {.transition.} =
  var ctx = s.NeutralizeContext
  let activeMask = ctx.manager.activeThreadMask.load(moAcquire)
  let currentTid = getThreadId().Pid

  for i in 0..<M:
    if (activeMask and (1'u64 shl i)) != 0:
      if ctx.manager.threads[i].pinned.load(moAcquire):
        let threadEpoch = ctx.manager.threads[i].epoch.load(moAcquire)
        if threadEpoch < ctx.threshold:
          let tid = ctx.manager.threads[i].osThreadId.load(moAcquire)
          if tid != Pid(0) and tid != currentTid:
            discard pthread_kill(tid, QuiescentSignal)
            inc ctx.signalsSent

  result = ScanComplete[M](ctx)
```

## Part 3: lockfreequeues Integration

### Remove EpochManager

Delete `src/lockfreequeues/epoch.nim` and replace with nim-debra import.

### Update Unbounded Queues

```nim
import debra

type
  UnboundedSipsic*[S: static int, T] = object
    manager*: ptr DebraManager[64]  # Use debra
    handle*: ThreadHandle[64]       # Thread's debra handle
    headSegment: ptr Segment[S, T]
    tailSegment: ptr Segment[S, T]
    strategy: DeallocationStrategy
    # ... rest unchanged
```

### Segment Retirement

When consumer finishes a segment:

```nim
proc retireSegment[S, T](q: var UnboundedSipsic[S, T], seg: ptr Segment[S, T]) =
  # Must be pinned to retire
  let pinned = q.handle.pin()
  let ready = pinned.toRetireReady()  # Bridge transition
  discard ready.retire(seg, proc(p: pointer) = c_free(p))
  discard pinned.unpin()

  if q.strategy == Eager:
    q.tryReclaim()
```

### `=destroy` Hook

```nim
proc `=destroy`[S: static int, T](q: UnboundedSipsic[S, T]) =
  # Free active segment chain (our private state)
  var seg = q.headSegment
  while seg != nil:
    let next = seg.next.load(moRelaxed)
    c_free(seg)
    seg = next

  # Retired segments stay in debra's limbo bags
  # They'll be reclaimed when safe
```

## Part 4: Documentation Structure

```
docs/
├── index.md                    # Overview, quick start, installation
├── guide/
│   ├── getting-started.md      # First example, basic usage
│   ├── concepts.md             # Epochs, pinning, reclamation explained
│   ├── thread-registration.md  # Registering threads
│   ├── pin-unpin.md            # Critical sections
│   ├── retiring-objects.md     # Limbo bags, retire API
│   ├── reclamation.md          # tryReclaim, safe epochs
│   ├── neutralization.md       # Signals, stalled threads
│   └── integration.md          # Using with lock-free structures
├── api/
│   ├── index.md                # API overview
│   ├── types.md                # DebraManager, ThreadHandle, etc.
│   └── typestates.md           # All typestate reference
└── contributing.md             # How to contribute
```

### MkDocs Configuration

```yaml
# mkdocs.yml
site_name: nim-debra
site_description: DEBRA+ safe memory reclamation for Nim
repo_url: https://github.com/elijahr/nim-debra

theme:
  name: material
  palette:
    primary: deep-purple
  features:
    - content.code.copy
    - navigation.sections

plugins:
  - search
  - mike  # Versioning

nav:
  - Home: index.md
  - Guide:
    - Getting Started: guide/getting-started.md
    - Concepts: guide/concepts.md
    - Thread Registration: guide/thread-registration.md
    - Pin/Unpin: guide/pin-unpin.md
    - Retiring Objects: guide/retiring-objects.md
    - Reclamation: guide/reclamation.md
    - Neutralization: guide/neutralization.md
    - Integration: guide/integration.md
  - API Reference: api/index.md
  - Contributing: contributing.md

markdown_extensions:
  - pymdownx.highlight
  - pymdownx.superfences
  - admonition
  - toc:
      permalink: true
```

## Implementation Order

1. **Rewrite nim-debra with proper typestates** (using nim-typestates library)
2. **Add limbo bags** to ThreadState
3. **Add retire typestate** with bag management
4. **Update reclaim** to process limbo bags
5. **Update lockfreequeues** to use nim-debra
6. **Add `=destroy` hooks** to unbounded queues
7. **Write documentation**
8. **Add examples**

## Testing Strategy

- Unit tests for each typestate
- Integration tests for full retire/reclaim cycle
- Stress tests with multiple threads
- Memory leak detection with valgrind/ASan
