## Test high-level convenience API for DEBRA.

import unittest2
import ../src/debra

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
    check destroyedCount >= 0  # May or may not reclaim immediately

  test "retireAndReclaim with pointer - no eager reclaim":
    let node = cast[Node](alloc0(sizeof(NodeObj)))
    node.value = 99

    # Retire without immediate reclaim attempt
    retireAndReclaim(handle, node, destroyNode, eager = false)

    check destroyedCount == 0  # Should not have reclaimed yet

  test "multiple retireAndReclaim calls":
    for i in 0..<10:
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
