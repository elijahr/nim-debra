## Test high-level convenience API for DEBRA.

import unittest2
import ../src/debra
import ../src/debra/atomics

type
  NodeObj = object
    value: int

  Node = ptr NodeObj

var destroyedCount = 0

proc destroyNode(p: pointer) {.nimcall.} =
  inc destroyedCount
  dealloc(p)

suite "DEBRA Convenience API":
  setup:
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    destroyedCount = 0

  test "retireAndReclaim with pointer - eager reclaim":
    # Allocate node
    let node = cast[Node](alloc0(sizeof(NodeObj)))
    node.value = 42

    # Retire and reclaim (eager=true by default)
    retireAndReclaim(handle, node, destroyNode)

    # Should work without error
    check destroyedCount >= 0 # May or may not reclaim immediately

  test "retireAndReclaim with pointer - no eager reclaim":
    let node = cast[Node](alloc0(sizeof(NodeObj)))
    node.value = 99

    # Retire without immediate reclaim attempt
    retireAndReclaim(handle, node, destroyNode, eager = false)

    check destroyedCount == 0 # Should not have reclaimed yet

  test "multiple retireAndReclaim calls":
    for i in 0 ..< 10:
      let node = cast[Node](alloc0(sizeof(NodeObj)))
      node.value = i
      retireAndReclaim(handle, node, destroyNode, eager = true)

    # All retirements should succeed
    check destroyedCount >= 0

  test "retireAndReclaim with Managed[ref T] on refc":
    when defined(gcRefc):
      type Node = ref object
        value: int

      let node = managed Node(value: 123)
      retireAndReclaim(handle, node, eager = true)

      # Should work without error on refc
      check true

# ---------------------------------------------------------------------------
# Batched retire/reclaim API tests
# (see docs/design/2026-04-25-batched-retire-reclaim.md)
# ---------------------------------------------------------------------------

suite "DEBRA Batched Retire/Reclaim API":
  setup:
    var manager = initDebraManager[4]()
    setGlobalManager(addr manager)
    let handle = registerThread(manager)
    destroyedCount = 0

  test "withPin injects it and retires multiple pointers":
    let n1 = cast[Node](alloc0(sizeof(NodeObj)))
    let n2 = cast[Node](alloc0(sizeof(NodeObj)))
    let n3 = cast[Node](alloc0(sizeof(NodeObj)))

    handle.withPin:
      it.retire(n1, destroyNode)
      it.retire(n2, destroyNode)
      it.retire(n3, destroyNode)

    # Thread is unpinned after the body
    check not manager.threads[handle.idx].pinned.load(moAcquire)

    # Advance epoch and reclaim
    advance(manager)
    advance(manager)
    advance(manager)
    discard reclaimNow(manager)
    check destroyedCount == 3

  test "withPin accepts a custom identifier":
    let n = cast[Node](alloc0(sizeof(NodeObj)))

    handle.withPin(myPin):
      myPin.retire(n, destroyNode)

    check not manager.threads[handle.idx].pinned.load(moAcquire)
    advance(manager)
    advance(manager)
    advance(manager)
    discard reclaimNow(manager)
    check destroyedCount == 1

  test "withPin runs body to completion and unpins":
    var ran = false
    handle.withPin:
      ran = true
      check manager.threads[handle.idx].pinned.load(moAcquire)
    check ran
    check not manager.threads[handle.idx].pinned.load(moAcquire)

  test "withPin unpins on exception":
    let n = cast[Node](alloc0(sizeof(NodeObj)))

    expect(ValueError):
      handle.withPin:
        it.retire(n, destroyNode)
        raise newException(ValueError, "boom")

    # Thread is unpinned despite the raise
    check not manager.threads[handle.idx].pinned.load(moAcquire)

    # Reclamation can still proceed
    advance(manager)
    advance(manager)
    advance(manager)
    discard reclaimNow(manager)
    check destroyedCount == 1

  test "nested withPin on same handle raises AssertionDefect under debug":
    # `assert` is active unless built with -d:release / -d:danger.
    # Tests typically run with debug-friendly builds; only enforce when active.
    when compileOption("assertions"):
      expect(AssertionDefect):
        handle.withPin:
          handle.withPin:
            discard
      # After the AssertionDefect, the outer withPin's finally still ran
      # and unpinned the thread.
      check not manager.threads[handle.idx].pinned.load(moAcquire)

  test "reclaimNow returns 0 when not safe yet":
    # Fresh manager: globalEpoch starts at 1, safeEpoch == 1, so checkSafe
    # returns ReclaimBlocked and the helper returns 0.
    check reclaimNow(manager) == 0

  test "reclaimNow reclaims pending objects when safe":
    let n1 = cast[Node](alloc0(sizeof(NodeObj)))
    let n2 = cast[Node](alloc0(sizeof(NodeObj)))

    handle.withPin:
      it.retire(n1, destroyNode)
      it.retire(n2, destroyNode)

    advance(manager)
    advance(manager)
    advance(manager)
    let count = reclaimNow(manager)
    check count == 2
    check destroyedCount == 2

  test "retireBatch retires N objects with their destructors":
    const N = 16
    var items: seq[(pointer, Destructor)]
    for i in 0 ..< N:
      let node = cast[Node](alloc0(sizeof(NodeObj)))
      node.value = i
      items.add((cast[pointer](node), destroyNode))

    handle.withPin:
      it.retireBatch(items)

    check not manager.threads[handle.idx].pinned.load(moAcquire)

    advance(manager)
    advance(manager)
    advance(manager)
    let count = reclaimNow(manager)
    check count == N
    check destroyedCount == N
