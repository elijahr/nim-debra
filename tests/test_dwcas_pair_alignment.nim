# tests/test_dwcas_pair_alignment.nim
##
## Pair alignment positive tests + 1-byte-offset misalignment negative
## (impl plan Task 16, design §8.5).
##
## Positive: Pair[uint64, uint64] elements stay 16-byte aligned when:
##   * Sequence-allocated via newSeq.
##   * Array-allocated as an Atomic[Pair[...]].
##   * Embedded in an outer object (mirrors lockfreequeues Segment shape).
##
## Negative: deliberately misalign a Pair-typed pointer by +1 byte and
## verify the debug-mode runtime `doAssert` in the public load proc
## fires. Locked behind `when not defined(release)` to match the assert
## guard in src/debra/atomics.nim.

import unittest2

import debra/atomics

type P = Pair[uint64, uint64]

suite "DWCAS Pair alignment (positive)":
  test "newSeq[Pair[uint64, uint64]] elements are 16-byte aligned":
    var s = newSeq[P](16)
    for i in 0 ..< s.len:
      check (cast[uint](addr s[i]) mod 16'u) == 0'u

  test "array[16, Atomic[Pair[uint64, uint64]]] elements are 16-byte aligned":
    var arr: array[16, Atomic[P]]
    for i in 0 ..< arr.len:
      check (cast[uint](addr arr[i]) mod 16'u) == 0'u

  test "Pair embedded in outer object is 16-byte aligned":
    type Segment = object
      committed: array[16, Atomic[P]]
    var seg: Segment
    for i in 0 ..< seg.committed.len:
      check (cast[uint](addr seg.committed[i]) mod 16'u) == 0'u

  test "stack-local Atomic[Pair[uint64, uint64]] is 16-byte aligned":
    var a: Atomic[P]
    check (cast[uint](addr a) mod 16'u) == 0'u

suite "DWCAS Pair alignment (negative: 1-byte misalign trips debug assert)":
  test "deliberate +1-byte misaligned load trips AssertionDefect in debug builds":
    # The public load proc carries a `when not defined(release): doAssert
    # (cast[uint](addr loc) and 15'u) == 0'u` runtime check. Synthesize
    # a misaligned Pair pointer and verify the assert fires.
    when defined(release):
      skip()
    else:
      # 32-byte buffer: enough for a 16-byte aligned base + 1-byte offset
      # + 16 bytes payload.
      var buf {.align: 16.}: array[48, byte]
      let aligned = (cast[uint](addr buf[0]) + 15'u) and not 15'u
      doAssert (aligned mod 16'u) == 0'u  # sanity: base is aligned
      let misaligned = cast[ptr Atomic[P]](aligned + 1'u)
      doAssert (cast[uint](misaligned) mod 16'u) == 1'u  # confirmed +1

      expect AssertionDefect:
        discard misaligned[].load()
