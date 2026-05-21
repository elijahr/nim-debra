## Tests for `PinnedScope.retireOnCAS` and `retireOnPublish`.
##
## Cases cover the 9 scenarios spelled in the v0.8.0 phase-1 plan §4
## Step 6: CAS success/failure, rotation invariant, while-loop shape,
## ccMulti, retireOnPublish stores + retires, loop of retireOnPublish,
## retireOnCAS + retireOnPublish interleaved, and the empty-scope
## no-retire path.

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

suite "retireOnCAS + retireOnPublish":
  setup:
    var manager {.inject.} = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle {.inject.} = registerThread(manager)
    destroyedCount = 0

  test "retireOnCAS success retires the displaced pointer":
    var slot: Atomic[ptr NodeObj]
    let a = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    a.value = 1
    slot.store(a, moRelease)
    let b = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    b.value = 2

    var scope = pinScope(unpinned(handle))
    var exp = slot.load(moAcquire)
    let ok = scope.retireOnCAS(slot, exp, b, dtor)
    check ok == true
    check slot.load(moAcquire) == b
    check manager.threads[handle.idx].currentBag != nil
    check manager.threads[handle.idx].currentBag.count == 1

    # Defuse the live pointer so the suite teardown doesn't leak.
    discard slot.exchange(nil, moAcquireRelease)
    dealloc(b)

  test "retireOnCAS failure retires nothing":
    var slot: Atomic[ptr NodeObj]
    let a = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    a.value = 1
    slot.store(a, moRelease)
    let other = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    other.value = 99
    let b = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    b.value = 2

    var scope = pinScope(unpinned(handle))
    var exp = other # deliberately wrong expected value
    let ok = scope.retireOnCAS(slot, exp, b, dtor)
    check ok == false
    check slot.load(moAcquire) == a # slot unchanged
    # No bag should have been allocated.
    check manager.threads[handle.idx].currentBag == nil

    # Cleanup the unused allocations.
    dealloc(other)
    dealloc(b)
    discard slot.exchange(nil, moAcquireRelease)
    dealloc(a)

  test "rotation invariant: scope.state.epoch unchanged after retireOnCAS":
    var slot: Atomic[ptr NodeObj]
    let a = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    slot.store(a, moRelease)
    let b = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))

    var scope = pinScope(unpinned(handle))
    let epoch1 = scope.state.epoch
    var exp = slot.load(moAcquire)
    discard scope.retireOnCAS(slot, exp, b, dtor)
    let epoch2 = scope.state.epoch
    # Rotation through RetireReady -> Retired -> Pinned does NOT advance
    # the epoch; the slot's pinned flag is unchanged.
    check epoch1 == epoch2
    check manager.threads[handle.idx].pinned.load(moAcquire) == true

    discard slot.exchange(nil, moAcquireRelease)
    dealloc(b)

  test "while-loop shape: CAS retry to publish a successor":
    var slot: Atomic[ptr NodeObj]
    let initial = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    initial.value = 0
    slot.store(initial, moRelease)
    let successor = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    successor.value = 1

    var scope = pinScope(unpinned(handle))
    var loops = 0
    while true:
      inc loops
      let exp = slot.load(moAcquire)
      if scope.retireOnCAS(slot, exp, successor, dtor):
        break
      check loops < 16 # guard against runaway retries
    check slot.load(moAcquire) == successor
    check manager.threads[handle.idx].currentBag.count == 1

    discard slot.exchange(nil, moAcquireRelease)
    dealloc(successor)

  test "retireOnCAS under [MT, ccMulti]":
    var mgr: DebraManager[4, ccMulti]
    mgr.globalEpoch.store(1'u64, moRelaxed)
    mgr.activeThreadMask.store(0'u64, moRelaxed)
    mgr.boundClients.store(0, moRelaxed)
    for i in 0 ..< 4:
      mgr.threads[i].epoch.store(0'u64, moRelaxed)
      mgr.threads[i].pinned.store(false, moRelaxed)
      mgr.threads[i].neutralized.store(false, moRelaxed)
      mgr.threads[i].threadId.store(InvalidThreadId, moRelaxed)
      mgr.threads[i].currentBag = nil
      mgr.threads[i].limboBagTail = nil
    # NOTE: setGlobalManager not widened to ccMulti yet; ccMulti retire
    # path does not require it.

    let u = unregistered[4, ccMulti](addr mgr)
    var regResult = u.register()
    var mhandle: ThreadHandle[4, ccMulti]
    match regResult:
      Registered(reg):
        mhandle = reg.getHandle()
      RegistrationFull(_):
        check false

    var slot: Atomic[ptr NodeObj]
    let a = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    slot.store(a, moRelease)
    let b = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))

    block:
      var scope = pinScope(unpinned(mhandle))
      var exp = slot.load(moAcquire)
      let ok = scope.retireOnCAS(slot, exp, b, dtor)
      check ok == true
    check mgr.threads[mhandle.idx].pinned.load(moAcquire) == false

    discard slot.exchange(nil, moAcquireRelease)
    dealloc(b)

  test "retireOnPublish stores and retires the displaced value":
    var slot: Atomic[ptr NodeObj]
    let a = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    a.value = 1
    slot.store(a, moRelease)
    let b = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    b.value = 2

    var scope = pinScope(unpinned(handle))
    scope.retireOnPublish(slot, b, dtor)
    check slot.load(moAcquire) == b
    check manager.threads[handle.idx].currentBag != nil
    check manager.threads[handle.idx].currentBag.count == 1

    discard slot.exchange(nil, moAcquireRelease)
    dealloc(b)

  test "loop of retireOnPublish queues N retires":
    var slot: Atomic[ptr NodeObj]
    let initial = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    slot.store(initial, moRelease)
    const N = 5

    var scope = pinScope(unpinned(handle))
    for i in 1 .. N:
      let next = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
      next.value = i
      scope.retireOnPublish(slot, next, dtor)
    check manager.threads[handle.idx].currentBag.count == N

    let final = slot.load(moAcquire)
    discard slot.exchange(nil, moAcquireRelease)
    dealloc(final)

  test "retireOnCAS + retireOnPublish interleaved within one scope":
    var slot: Atomic[ptr NodeObj]
    let initial = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    initial.value = 0
    slot.store(initial, moRelease)
    let viaCas = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    viaCas.value = 1
    let viaPublish = cast[ptr NodeObj](alloc0(sizeof(NodeObj)))
    viaPublish.value = 2

    var scope = pinScope(unpinned(handle))
    var exp = slot.load(moAcquire)
    check scope.retireOnCAS(slot, exp, viaCas, dtor) == true
    scope.retireOnPublish(slot, viaPublish, dtor)
    check slot.load(moAcquire) == viaPublish
    check manager.threads[handle.idx].currentBag.count == 2

    discard slot.exchange(nil, moAcquireRelease)
    dealloc(viaPublish)

  test "empty scope: no retire calls means no bag allocation":
    block:
      var scope {.used.} = pinScope(unpinned(handle))
      # No retire calls inside the scope.
    check manager.threads[handle.idx].pinned.load(moAcquire) == false
    check manager.threads[handle.idx].currentBag == nil
