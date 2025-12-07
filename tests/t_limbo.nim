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
