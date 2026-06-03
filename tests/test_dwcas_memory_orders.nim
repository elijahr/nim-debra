# tests/test_dwcas_memory_orders.nim
##
## DWCAS memory-order matrix (impl plan Task 12a, design §8.1).
##
## Verifies that every valid MemoryOrder for each op (load / store /
## exchange / CAS-strong / CAS-weak) is accepted and round-trips
## correctly. Per design §3, the upgrade only STRENGTHENS to
## moSequentiallyConsistent at the instruction level, so correctness
## must hold for every value of the order parameter.
##
## Invalid-order rejection is verified by the companion should_fail
## fixtures: tests/should_fail/t_dwcas_load_moRelease.nim,
## t_dwcas_store_moAcquire.nim, and t_dwcas_cas_failure_moRelease.nim.
##
## Each call site that passes a sub-seq_cst order is wrapped in
## `dwcasOrderRelaxedCAS:` so the compile-time warning does not fire
## (the matrix is exhaustive by construction; the warning would
## otherwise spam the build).
##
## Wired into tests/test.nim — runs under all four MM modes.

import unittest2

import debra/atomics

type P = Pair[uint64, uint64]

const
  ValidLoadOrders = [moRelaxed, moConsume, moAcquire, moSequentiallyConsistent]
  ValidStoreOrders = [moRelaxed, moRelease, moSequentiallyConsistent]
  AllOrders = [
    moRelaxed, moConsume, moAcquire, moRelease, moAcquireRelease,
    moSequentiallyConsistent,
  ]

suite "DWCAS memory-order matrix (positive: every valid order round-trips)":
  test "load accepts every valid load-order":
    # Use static for-loop unrolling so `order` is a compile-time value
    # (required by `static MemoryOrder` parameter).
    template body(ord: static MemoryOrder) =
      var a: Atomic[P]
      a.store(Pair[uint64, uint64](first: 7'u64, second: 11'u64))
      dwcasOrderRelaxedCAS:
        let r = a.load(ord)
        check r.first == 7'u64
        check r.second == 11'u64

    body(moRelaxed)
    body(moConsume)
    body(moAcquire)
    body(moSequentiallyConsistent)

  test "store accepts every valid store-order":
    template body(ord: static MemoryOrder) =
      var a: Atomic[P]
      dwcasOrderRelaxedCAS:
        a.store(Pair[uint64, uint64](first: 3'u64, second: 5'u64), ord)
      check a.load() == Pair[uint64, uint64](first: 3'u64, second: 5'u64)

    body(moRelaxed)
    body(moRelease)
    body(moSequentiallyConsistent)

  test "exchange accepts every memory order":
    template body(ord: static MemoryOrder) =
      var a: Atomic[P]
      a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
      dwcasOrderRelaxedCAS:
        let prev = a.exchange(Pair[uint64, uint64](first: 9'u64, second: 9'u64), ord)
        check prev.first == 1'u64
      check a.load() == Pair[uint64, uint64](first: 9'u64, second: 9'u64)

    body(moRelaxed)
    body(moConsume)
    body(moAcquire)
    body(moRelease)
    body(moAcquireRelease)
    body(moSequentiallyConsistent)

  test "compareExchangeStrong accepts every (success, failure) order pair":
    # Failure order must be load-compatible (validCasFailureOrder rejects
    # moRelease / moAcquireRelease as failure orders), AND must be no
    # stronger than the LOAD component of the success order per C11
    # §7.17.7.4. The lattice is non-trivial only for success=moRelease:
    # moRelease has no load-acquire on the success path, so failure must
    # be moRelaxed. Other success orders use ord-comparison correctly.
    template casBody(sOrd, fOrd: static MemoryOrder) =
      when ord(fOrd) <= ord(sOrd) and fOrd != moRelease and fOrd != moAcquireRelease and
          not (sOrd == moRelease and fOrd != moRelaxed):
        var a: Atomic[P]
        a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
        var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
        dwcasOrderRelaxedCAS:
          check a.compareExchangeStrong(
            expected, Pair[uint64, uint64](first: 5'u64, second: 6'u64), sOrd, fOrd
          )
        check a.load() == Pair[uint64, uint64](first: 5'u64, second: 6'u64)

    # 6 success orders × 4 valid failure orders, filtered by
    # ord(failure) <= ord(success).
    template runRow(sOrd: static MemoryOrder) =
      casBody(sOrd, moRelaxed)
      casBody(sOrd, moConsume)
      casBody(sOrd, moAcquire)
      casBody(sOrd, moSequentiallyConsistent)

    runRow(moRelaxed)
    runRow(moConsume)
    runRow(moAcquire)
    runRow(moRelease)
    runRow(moAcquireRelease)
    runRow(moSequentiallyConsistent)

  test "compareExchangeWeak accepts every (success, failure) order pair":
    template casBody(sOrd, fOrd: static MemoryOrder) =
      when ord(fOrd) <= ord(sOrd) and fOrd != moRelease and fOrd != moAcquireRelease and
          not (sOrd == moRelease and fOrd != moRelaxed):
        var ok = false
        var a: Atomic[P]
        # Loop to absorb spurious weak failures on aarch64 LL/SC.
        for _ in 0 ..< 64:
          a.store(Pair[uint64, uint64](first: 1'u64, second: 2'u64))
          var expected = Pair[uint64, uint64](first: 1'u64, second: 2'u64)
          dwcasOrderRelaxedCAS:
            if a.compareExchangeWeak(
              expected, Pair[uint64, uint64](first: 5'u64, second: 6'u64), sOrd, fOrd
            ):
              ok = true
              break
        check ok

    template runRow(sOrd: static MemoryOrder) =
      casBody(sOrd, moRelaxed)
      casBody(sOrd, moConsume)
      casBody(sOrd, moAcquire)
      casBody(sOrd, moSequentiallyConsistent)

    runRow(moRelaxed)
    runRow(moConsume)
    runRow(moAcquire)
    runRow(moRelease)
    runRow(moAcquireRelease)
    runRow(moSequentiallyConsistent)
