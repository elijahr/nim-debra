import unittest2
import std/atomics

import debra/managed

suite "Managed type":
  test "managed creates Managed[T] from ref":
    type Node = ref object
      value: int

    let node = managed Node(value: 42)
    check node is Managed[Node]

  test "inner returns underlying ref":
    type Node = ref object
      value: int

    let node = managed Node(value: 42)
    check node.inner is Node
    check node.inner.value == 42

  test "dot template provides field access":
    type Node = ref object
      value: int
      name: string

    let node = managed Node(value: 42, name: "test")
    check node.value == 42
    check node.name == "test"

  test "isNil works on Managed":
    type Node = ref object
      value: int

    let nilNode: Managed[Node] = Managed[Node](nil)
    let node = managed Node(value: 1)
    check nilNode.isNil
    check not node.isNil

  test "equality works on Managed":
    type Node = ref object
      value: int

    let a = managed Node(value: 1)
    let b = a
    let c = managed Node(value: 1)
    check a == b
    check a != c # Different refs

  test "Atomic[Managed[T]] works":
    type Node = ref object
      value: int

    var head: Atomic[Managed[Node]]
    let node = managed Node(value: 42)
    head.store(node, moRelaxed)
    let loaded = head.load(moRelaxed)
    check loaded.value == 42

  test "CAS works with Managed":
    type Node = ref object
      value: int

    var head: Atomic[Managed[Node]]
    let node1 = managed Node(value: 1)
    let node2 = managed Node(value: 2)

    head.store(node1, moRelaxed)
    var expected = node1
    check head.compareExchange(expected, node2, moRelease, moRelaxed)
    check head.load(moRelaxed).value == 2

  test "GC_ref is called on managed":
    # Verify object survives scope exit when managed
    # This test verifies the managed proc calls GC_ref
    # by checking that multiple references to the same object work
    type TestObj = ref object
      id: int

    var survived: Managed[TestObj]
    block:
      let obj = managed TestObj(id: 1)
      survived = obj
      # If GC_ref wasn't called, object might be collected here

    # Object should still be accessible
    check survived.id == 1
    check not survived.isNil
