import unittest2

import debra/limbo

suite "LimboBag":
  test "LimboBagSize is 64":
    check LimboBagSize == 64

  test "allocLimboBag returns non-nil":
    let bag = allocLimboBag()
    check bag != nil
    check bag.count == 0
    check bag.epoch == 0
    check bag.next == nil
    freeLimboBag(bag)

  test "RetiredObject stores data and destructor":
    var destructorCalled = false

    proc myDestructor(p: pointer) {.nimcall.} =
      if not p.isNil:
        var flag = cast[ptr bool](p)
        flag[] = true

    var flag = destructorCalled
    var obj = RetiredObject(data: addr flag, destructor: myDestructor)
    obj.destructor(obj.data)
    check flag == true

  test "reclaimBag with single object and destructor":
    var destructorCallCount = 0

    proc countingDestructor(p: pointer) {.nimcall.} =
      if not p.isNil:
        var counter = cast[ptr int](p)
        counter[] += 1

    let bag = allocLimboBag()
    bag.objects[0] = RetiredObject(data: addr destructorCallCount, destructor: countingDestructor)
    bag.count = 1

    reclaimBag(bag)
    check destructorCallCount == 1

  test "reclaimBag with multiple objects":
    var destructorCallCount = 0

    proc countingDestructor(p: pointer) {.nimcall.} =
      if not p.isNil:
        var counter = cast[ptr int](p)
        counter[] += 1

    let bag = allocLimboBag()
    for i in 0..<5:
      bag.objects[i] = RetiredObject(data: addr destructorCallCount, destructor: countingDestructor)
    bag.count = 5

    reclaimBag(bag)
    check destructorCallCount == 5

  test "reclaimBag with nil destructor does not crash":
    var dummyData: int = 42

    let bag = allocLimboBag()
    bag.objects[0] = RetiredObject(data: addr dummyData, destructor: nil)
    bag.objects[1] = RetiredObject(data: nil, destructor: nil)
    bag.count = 2

    # Should not crash
    reclaimBag(bag)
    check true  # If we reach here, test passed

  test "reclaimBag with mixed destructors":
    var counter1 = 0
    var counter2 = 0

    proc destructor1(p: pointer) {.nimcall.} =
      if not p.isNil:
        var c = cast[ptr int](p)
        c[] += 10

    proc destructor2(p: pointer) {.nimcall.} =
      if not p.isNil:
        var c = cast[ptr int](p)
        c[] += 20

    let bag = allocLimboBag()
    bag.objects[0] = RetiredObject(data: addr counter1, destructor: destructor1)
    bag.objects[1] = RetiredObject(data: addr counter2, destructor: destructor2)
    bag.objects[2] = RetiredObject(data: nil, destructor: nil)
    bag.objects[3] = RetiredObject(data: addr counter1, destructor: destructor1)
    bag.count = 4

    reclaimBag(bag)
    check counter1 == 20  # destructor1 called twice: 10 + 10
    check counter2 == 20  # destructor2 called once: 20
