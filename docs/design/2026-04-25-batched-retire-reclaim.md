# Batched Retire/Reclaim Ergonomics for nim-debra

Status: Draft. Author: project maintainer. Date: 2026-04-25.

## 1. Motivation

Every retirement site in lockfreequeues' three unbounded queues open-codes the
same 8-step typestate ceremony. Concrete site (`unbounded_sipmuc.nim:208-244`):

```nim
let pinned = unpinned(self.handle).pin()
# ... CAS loop, slot claim ...
if mySlot == S - 1 and self.queue.strategy != Manual:
  let ready = retireReady(pinned)
  discard ready.retire(cast[pointer](seg), segmentDestructor)
  discard self.queue.segments.fetchSub(1, moRelaxed)
discard pinned.unpin()
if self.queue.strategy == Eager:
  let reclaimOp = reclaimStart(self.queue.manager).loadEpochs().checkSafe()
  if reclaimOp.kind == rReclaimReady:
    discard reclaimOp.reclaimready.tryReclaim()
```

`unbounded_mupsic.nim:233-271` and `unbounded_mupmuc.nim:239-288` repeat it
with subtle differences (sipmuc/mupmuc retire on slot `S-1`; mupsic retires
inside a walk loop). All gate retire on `strategy != Manual` and reclaim on
`strategy == Eager`. None batches.

Typestates make this safe (no retire without `Pinned`, no reclaim without
`safeEpoch > 1`) but not short. Every site repeats pin, optional retire,
unpin, optional reclaim, plus `discard` noise from sink returns.

Constraint: do not change `typestates/{guard,retire,reclaim}.nim`. The state
machine `Unpinned -> Pinned -> RetireReady -> Retired -> Pinned -> Unpinned`
is the safety floor. Build sugar on top, preserving the low-level API for
holding `Pinned` across complex CAS loops.

`retireAndReclaim` (`convenience.nim:13-88`) handles the single-object eager
case but cannot batch (each call pins/unpins/reclaims fresh) and cannot wrap
a CAS loop in a single epoch.

## 2. API Surface: Core Patterns

Four patterns cover the observed call sites and the foreseeable future.

### 2.1 `withPin` template: scoped pinned epoch

Two overloaded forms, both implemented as templates. Nim resolves on arity.

```nim
template withPin*[MT: static int](
    th: ThreadHandle[MT], body: untyped
): untyped
  ## Default form: injects `it` as `var RetireReady[MT]` (matches the
  ## Nim convention used by `filterIt`/`mapIt`). Pins the calling thread,
  ## runs body, unpins on exit including exception paths. Body may call
  ## `it.retire(p, dtor)` zero or more times.

template withPin*[MT: static int](
    th: ThreadHandle[MT], name, body: untyped
): untyped
  ## Named form: injects `name` (caller-supplied identifier) as
  ## `var RetireReady[MT]`. Use to disambiguate nested handles.
```

The template parameter is named `th` (not `handle`) to avoid colliding
with `EpochGuardContext.handle` field references inside the template body.

Call sites (sipmuc retire site, default and named forms):

```nim
self.handle.withPin:
  # ... CAS loop using moAcquire/moRelaxed as today ...
  if mySlot == S - 1 and self.queue.strategy != Manual:
    it.retire(cast[pointer](seg), segmentDestructor)
    discard self.queue.segments.fetchSub(1, moRelaxed)

# Or with a custom name (multi-handle scenarios):
outer.withPin(outerPin):
  inner.withPin(innerPin):
    outerPin.retire(p1, dtor)
    innerPin.retire(p2, dtor)
```

Compile-time guarantees that survive: `it` is a `var RetireReady[MT]`,
which means `retire` returns `Retired` and we re-derive `RetireReady` for
the next call (the template handles this internally via
`retireReadyFromRetired`, `retire.nim:32-36`). The body cannot accidentally
escape `it` because templates expand inline and `it` is a local symbol.
The body cannot start a second pin on the same handle without nesting (see
section 5.3). Exception safety is provided by `try/finally` (section 3b).

### 2.2 `retireBatch` proc: batched retire inside a pin

```nim
proc retireBatch*[MT: static int](
    pin: var RetireReady[MT], items: openArray[(pointer, Destructor)]
)
  ## Retire each (p, dtor) in items inside an existing pinned epoch.
  ## Must be called from within `withPin` body (or any other holder of
  ## a `var RetireReady[MT]`). No pinning, no reclamation.
```

For freeing a chain of segments inside a single pinned epoch. Use case:

```nim
self.handle.withPin:
  var batch: seq[(pointer, Destructor)]
  var seg = self.headSegment
  while seg != nil:
    batch.add((cast[pointer](seg), segmentDestructor))
    seg = seg.next.load(moAcquire)
  it.retireBatch(batch)
```

### 2.3 `reclaimNow` proc: standalone reclamation pass

```nim
proc reclaimNow*[MT: static int](manager: var DebraManager[MT]): int
  ## Run one reclaim attempt. Returns count reclaimed (0 if blocked).
  ## No pinning: reclamation does not require it.
```

Collapses the four-call sequence
`reclaimStart(mgr).loadEpochs().checkSafe()` plus the `kind == rReclaimReady`
branch (see `reclaim.nim:31-67`) into one line. Named `reclaimNow` (not
`tryReclaim`) to coexist unambiguously with the typestate-level `tryReclaim`
on `ReclaimReady`. Call site:

```nim
if self.queue.strategy == Eager:
  discard reclaimNow(self.queue.manager)
```

### 2.4 `retireAndReclaim` (existing, retained)

Stays as-is for the single-object eager case (`convenience.nim:13-88`). New
patterns subsume it for new code, but it is the right tool for "retire one
object, attempt reclaim, done."

## 3. Decision Points

**a) Template vs proc vs macro.** `withPin` is a template. Body capture is
required (the body uses outer locals like `mySlot`, `seg`, `self.queue`).
A proc would force a closure, which allocates and breaks the lock-free
contract. A macro is heavier than necessary; templates already give us
hygiene and inline expansion. `retireBatch` and `tryReclaim` are procs:
no body capture, plain procs compile cleaner.

**b) Exception safety.** `withPin` wraps body in `try/finally`. Pattern:

```
let pinned = unpinned(th).pin()
var it {.inject.} = retireReady(pinned)
try:
  body
finally:
  let ctx = RetireContext[MT](it)
  let p = Pinned[MT](EpochGuardContext[MT](handle: ctx.handle, epoch: ctx.epoch))
  discard p.unpin()
```

Required: a leaked pin pins the global epoch indefinitely, blocking
reclamation across all threads. `try/finally` is non-negotiable. `retireBatch`
uses the same pattern internally.

**c) API surface placement.** Extend `convenience.nim` rather than adding
`scope.nim`. Existing `retireAndReclaim` already lives there and the new
APIs are the same shape (high-level wrappers over typestates). One import
for users. If the file grows past ~200 lines, split later.

**d) Naming.** `withPin` matches `withLock`/`withValue` and beats
considered alternatives (`pinScope` less idiomatic; `pinned` collides
with the state; `inEpoch` opaque; `protect` carries hazard-pointer
baggage). Default injected identifier is `it` (a `var RetireReady[MT]`),
matching the convention used by `filterIt`/`mapIt` in the Nim stdlib;
the named overload takes a user-supplied identifier for nested-handle
disambiguation. The template parameter is `th` rather than `handle` to
avoid colliding with `EpochGuardContext.handle` field references inside
the template body. Batched proc: `retireBatch`. Reclaim helper: `reclaimNow`,
named distinctly from the typestate-level `tryReclaim` to avoid reader
confusion despite arg-type uniqueness.

**e) Backward compat.** `retireAndReclaim` stays unchanged. Not deprecated.
It remains the right tool for one-shot single retires with eager reclaim,
which is a real use case outside queues. Documented as "convenience for the
single-object case; for CAS loops or batches, prefer `withPin`."

## 4. Concrete Call-Site Comparisons

**sipmuc** (`unbounded_sipmuc.nim:208-244`, 9 retire-related lines BEFORE):

```nim
# AFTER (4 lines of retire/reclaim plumbing):
self.handle.withPin:
  # ... CAS loop body unchanged ...
  if mySlot == S - 1 and self.queue.strategy != Manual:
    it.retire(cast[pointer](seg), segmentDestructor)
    discard self.queue.segments.fetchSub(1, moRelaxed)
if self.queue.strategy == Eager: discard reclaimNow(self.queue.manager[])
```

**mupsic** (`unbounded_mupsic.nim:233-271`, retire interleaved in walk loop):

```nim
# AFTER:
self.handle.withPin:
  var seg = self.headSegment
  while true:
    # ... existing logic ...
    if self.strategy != Manual:
      it.retire(cast[pointer](seg), segmentDestructor)
      discard self.segments.fetchSub(1, moRelaxed)
    self.headSegment = nextSeg
    seg = nextSeg
if self.strategy == Eager: discard reclaimNow(self.manager[])
```

**mupmuc** (`unbounded_mupmuc.nim:239-288`): identical shape to sipmuc.

Each site drops from 8 ceremony lines to 2-3. The CAS-loop body is unchanged;
the wrapper is what shrinks.

## 5. Memory Model Notes

**5.1 Epoch advancement.** `withPin` does not touch `globalEpoch`. Pinning
reads it (`guard.nim:43`) and writes the per-thread epoch slot. Repeated
`withPin` calls cost one acquire-load on `globalEpoch` each. Epoch
advancement is unchanged. No pessimism added.

**5.2 DeallocationStrategy.** The `Manual`/`Eager` enum
(`unbounded_sipmuc.nim:27-39`) is queue policy, not DEBRA policy. The
strategy decision stays at the queue level: queues pass `(p, dtor)` to
`retire` only when their own logic dictates, and call `tryReclaim(mgr)` only
when `strategy == Eager`. The new API does not bake strategy in. This is the
right boundary: DEBRA does not know what "Manual" means to the caller.

**5.3 Nested `withPin`.** Same-handle nesting is a programming error: the
inner unpin would fire too early. Detect at runtime via the per-thread
`pinned` flag (set in `guard.nim:46`). At entry to the `withPin` body,
`assert not handle.manager.threads[handle.idx].pinned.load(moAcquire)`
with a message naming the handle slot. Standard Nim `assert` raises
`AssertionDefect` in debug builds and is a no-op under `-d:release`/
`-d:danger`, matching the policy "active under debug, no-op in release"
without introducing a new `when` gate. Different-handle nesting
(multi-manager) is independent and legal.

## 6. Migration Plan

1. Land the new procs/template in `src/debra/convenience.nim` with tests.
2. Update lockfreequeues' three retire sites
   (`unbounded_{sipmuc,mupsic,mupmuc}.nim`).
3. Run the 173-test matrix on refc/arc/orc with `--threads:on/off` on Linux
   and macOS.
4. Future: migrate the four deferred nim-debra examples. Out of scope here.

## 7. Test Strategy

- `tests/convenience/withpin_basic.nim`: pin, retire two pointers, unpin;
  assert both destructors fire after a `tryReclaim` pass.
- `tests/convenience/withpin_exception.nim`: body raises `ValueError`; assert
  the per-thread `pinned` flag is false after the raise propagates and
  `tryReclaim` makes progress.
- `tests/convenience/retire_batch.nim`: `retireBatch` of 100 pointers, single
  `tryReclaim`, assert all 100 destructors fired exactly once.
- `tests/convenience/tryreclaim_blocked.nim`: another thread holds `Pinned`
  at the current epoch; `tryReclaim` returns 0; release, `tryReclaim` again
  returns N.
- `tests/convenience/withpin_nested_same_handle.nim`: under `-d:debug`,
  nested `withPin` on the same handle raises `AssertionDefect`.
- Existing `retireAndReclaim` tests unchanged; new tests run alongside.

## 8. Open Questions (Resolved)

1. **`withPin` identifier**: RESOLVED. Support both forms via overloaded
   templates: default `withPin(th): body` injects `it` (Nim convention,
   matches `filterIt`/`mapIt`), named `withPin(th, name): body` injects
   the caller's identifier. Nim's template-arity overloading dispatches.
2. **`reclaimNow` out-param for `safeEpoch`**: deferred. Add when a
   consumer needs it.
3. **Naming overlap**: RESOLVED. New helper named `reclaimNow` to avoid
   any reader confusion with the typestate-level `tryReclaim`.

## 9. Non-Goals

- Replacing the typestate API. It is the safety floor.
- Auto-reclamation policy (background thread, threshold-driven). Caller
  decides when to call `tryReclaim`.
- Wrapper-only retire variants; `withPin` supports the available retire overloads.
- Cross-manager single-body `withPin`. Compose by nesting different handles.
- Suppressing `discard` on retire inside the body. Template wraps so that
  `it.retire(...)` is statement-form; spec detail for implementation.
