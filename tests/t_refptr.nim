## Tests for `retain`/`release`/`releaseDestructor` helpers.

import unittest2

import ../src/debra
import ../src/debra/atomics
import ../src/debra/limbo
import ../src/debra/refptr

type
  NodeObj = object
    value: int

  Node = ref NodeObj

suite "refptr retain/release":
  test "retain returns a non-nil ptr to the underlying object":
    let n = Node(value: 7)
    let p = retain(n)
    check p != nil
    check p.value == 7
    # Balance the retain we just did so this test does not leak.
    release(p)

  test "release on nil is a no-op":
    var p: ptr NodeObj = nil
    release(p) # Must not crash.
    check p == nil

  test "multiple retain/release cycles balance":
    # Retain twice, release twice -> object reachable until matching releases.
    let n = Node(value: 42)
    let p1 = retain(n)
    let p2 = retain(n)
    check p1 == p2
    check p1.value == 42
    release(p1)
    # Object still alive after first release because the second retain holds it.
    check p2.value == 42
    release(p2)

  test "releaseDestructor[T] satisfies the Destructor signature":
    # Compile-time check: the result must coerce to `Destructor`.
    let dtor: Destructor = releaseDestructor[NodeObj]()
    check dtor != nil

  test "releaseDestructor[T] released the GC reference":
    # We cannot observe GC counts directly without internals, but we can
    # pass through the same code path the examples will use and verify
    # the destructor runs without crashing.
    let n = Node(value: 99)
    let p = retain(n)
    let dtor = releaseDestructor[NodeObj]()
    dtor(cast[pointer](p))
    # After this, `n`'s GC count is back to its pre-retain value, so the
    # local binding still keeps it alive for the rest of this scope.
    check n.value == 99

  test "Atomic[ptr T] storage round-trips through retain/release":
    var head: Atomic[ptr NodeObj]
    let n = Node(value: 5)
    let p = retain(n)
    head.store(p, moRelease)
    let loaded = head.load(moAcquire)
    check loaded == p
    check loaded.value == 5
    release(loaded)

  test "releaseDestructor handles nil pointer":
    let dtor = releaseDestructor[NodeObj]()
    dtor(nil) # Must not crash.
    check true
