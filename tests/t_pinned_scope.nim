## Tests for the PinnedScope RAII guard (debra/typestates/pinned_scope).
##
## Cases cover the 10 scenarios spelled in the v0.8.0 phase-1 plan §4
## Step 6: happy-path, =destroy on early return, =destroy on exception,
## =destroy after a Neutralized cycle, nested-pin AssertionDefect,
## no-copy compile rejection, move-safety, epoch snapshot, loop of
## retire, and ccMulti cardinality.

import unittest2

import debra
import debra/atomics
import debra/typestates/cardinality
import debra/typestates/guard
import debra/typestates/registration

type NodeObj = object
  value: int

var destroyedCount = 0

proc dtor(p: pointer) {.nimcall.} =
  inc destroyedCount
  dealloc(p)

suite "PinnedScope happy path + lifecycle":
  setup:
    var manager {.inject.} = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle {.inject.} = registerThread(manager)
    destroyedCount = 0

  test "happy path: block exit unpins via =destroy":
    block:
      var scope = pinScope(unpinned(handle))
      check manager.threads[handle.idx].pinned.load(moAcquire) == true
      discard scope.consumed
    # =destroy ran on block exit; slot is unpinned.
    check manager.threads[handle.idx].pinned.load(moAcquire) == false

  test "=destroy fires on early return":
    proc earlyReturn(h: ThreadHandle[4]) =
      var scope {.used.} = pinScope(unpinned(h))
      return

    earlyReturn(handle)
    check manager.threads[handle.idx].pinned.load(moAcquire) == false

  test "=destroy fires on exception":
    expect(ValueError):
      var scope {.used.} = pinScope(unpinned(handle))
      raise newException(ValueError, "boom")
    # The thrown exception unwinds past `scope`; its `=destroy` ran on
    # the way out and unpinned the slot.
    check manager.threads[handle.idx].pinned.load(moAcquire) == false

  test "=destroy clears Neutralized state via acknowledge + close":
    # Force the slot's neutralized flag so unpin returns Neutralized.
    manager.threads[handle.idx].neutralized.store(true, moRelease)
    block:
      var scope {.used.} = pinScope(unpinned(handle))
      check manager.threads[handle.idx].pinned.load(moAcquire) == true
    # =destroy walked the Neutralized arm: pinned cleared, neutralized
    # cleared by acknowledge().
    check manager.threads[handle.idx].pinned.load(moAcquire) == false
    check manager.threads[handle.idx].neutralized.load(moAcquire) == false

  test "nested pinScope on same handle hits AssertionDefect":
    # The constructor's doAssert fires only when assertions are active.
    when compileOption("assertions"):
      var outer {.used.} = pinScope(unpinned(handle))
      expect(AssertionDefect):
        var inner {.used.} = pinScope(unpinned(handle))
      # outer is still alive; its destructor runs at suite teardown.

  test "no-copy semantics: PinnedScope has =copy disabled":
    # NOTE: `=copy {.error.}` is a codegen-phase rejection, not a
    # semantic-phase one. `compiles(var b = a)` returns TRUE for such
    # types even though emitting the copy fails. The hard compile-fail
    # is therefore exercised in tests/should_fail/t_pinned_scope_copy.nim
    # via `nim c` + runner substring check. Here we record the runtime
    # invariant that pairs with non-copyability: a freshly constructed
    # scope is unconsumed, and moving it (Case 7) marks the source
    # consumed = true so a stray `=destroy` cannot double-unpin.
    var scope {.used.} = pinScope(unpinned(handle))
    check scope.consumed == false

  test "move-safety: moved-from scope destructor is a no-op":
    # The =wasMoved hook on PinnedScope marks the moved-from value as
    # consumed=true so a re-entrant =destroy is a no-op. refc does not
    # honour custom =wasMoved hooks (move semantics are ORC/ARC-family
    # only), so this regression check runs under managed-memory backends
    # that respect the move hook.
    when defined(gcOrc) or defined(gcArc) or defined(gcAtomicArc):
      var a = pinScope(unpinned(handle))
      var b = move(a)
      check a.consumed == true
      check b.consumed == false
      discard b
      discard a
    else:
      # refc: skip the move-hook check; document via a trivial assertion
      # so the case stays at 10 across backends.
      check true

  test "epoch snapshot: scope captures global epoch once":
    var scope = pinScope(unpinned(handle))
    let epoch1 = scope.state.epoch
    # Mutating the global epoch must not change the scope's captured
    # value: pin samples the global epoch once at construction.
    advance(manager)
    advance(manager)
    let epoch2 = scope.state.epoch
    check epoch1 == epoch2

  test "loop of retire: multiple retireOnCAS calls inside one scope":
    var slot: Atomic[ptr NodeObj]
    let initial = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    initial.value = 0
    slot.store(initial, moRelease)
    const Iterations = 4

    var scope = pinScope(unpinned(handle))
    for i in 1 .. Iterations:
      let next = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
      next.value = i
      var exp = slot.load(moAcquire)
      let ok = scope.retireOnCAS(slot, exp, next, dtor)
      check ok == true

    # N retires queued exactly N items in the current bag.
    check manager.threads[handle.idx].currentBag != nil
    check manager.threads[handle.idx].currentBag.count == Iterations
    # Free the live ptr so the test doesn't leak the final node.
    let final = slot.load(moAcquire)
    discard slot.exchange(nil, moAcquireRelease)
    dealloc(final)

suite "PinnedScope ccMulti cardinality":
  test "happy path under [MT, ccMulti]":
    # `initDebraManager` only emits `[MT, ccSingle]`; ccMulti requires
    # building the manager + driving the manager typestate by hand.
    var manager: DebraManager[4, ccMulti]
    manager.globalEpoch.store(1'u64, moRelaxed)
    manager.activeThreadMask.store(0'u64, moRelaxed)
    manager.boundClients.store(0, moRelaxed)
    for i in 0 ..< 4:
      manager.threads[i].epoch.store(0'u64, moRelaxed)
      manager.threads[i].pinned.store(false, moRelaxed)
      manager.threads[i].neutralized.store(false, moRelaxed)
      manager.threads[i].threadId.store(InvalidThreadId, moRelaxed)
      manager.threads[i].currentBag = nil
      manager.threads[i].limboBagTail = nil
    # NOTE: setGlobalManager has not been widened to accept
    # `ptr DebraManager[MaxThreads, ccMulti]` yet (step 8 territory).
    # The ccMulti happy-path test exercises pin/unpin only — no signals,
    # no neutralize — so a non-published global manager is acceptable.

    let u = unregistered[4, ccMulti](addr manager)
    var regResult = u.register()
    var handle: ThreadHandle[4, ccMulti]
    match regResult:
      Registered(reg):
        handle = reg.getHandle()
      RegistrationFull(_):
        check false # unreachable under fresh manager.

    block:
      var scope = pinScope(unpinned(handle))
      check manager.threads[handle.idx].pinned.load(moAcquire) == true
      discard scope.consumed
    check manager.threads[handle.idx].pinned.load(moAcquire) == false
