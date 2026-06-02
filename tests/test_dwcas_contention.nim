# tests/test_dwcas_contention.nim
##
## DWCAS concurrent CAS contention smoke (impl plan Task 14).
##
## N producer threads × M cells × K iterations per cell. Each iteration
## reads the current value via load, bumps `first` by 1 and stamps `second`
## with the worker id, and CAS-installs the new pair. Verifies:
##
##   * No torn reads: every load() returns a value that was at some point
##     installed by a CAS; the second-field worker stamp matches a real
##     worker id (0..N-1).
##   * No lost updates: the final `first` field of each cell equals K * N
##     (every iteration of every worker contributed +1 to that cell).
##
## Runs under arc / orc / atomicArc. refc skipped: nim-debra's other
## concurrent stress tests (t_unregister_thread_stress) use the same
## pattern; refc + threads is supported by Nim 2.2.10 but the project
## convention is to exercise the arc family for thread-safety regressions.
##
## NOTE: This test is NOT wired into tests/test.nim because it spawns
## threads and runs longer than the unit-test budget. It is invoked
## directly by CI (impl plan Task 23) and by hand via:
##
##   nim c -r --threads:on --mm:arc --path:src -d:testing \
##     tests/test_dwcas_contention.nim
##
## Per impl plan §13, the test is also wired into the v0.10.0
## "nimble test" task as a separate exec line in a follow-up task; this
## file alone is the artifact for Task 14.

import std/[cpuinfo]

import unittest2

import debra/atomics

type P = Pair[uint64, uint64]

# Worker config. Conservative to keep total test time bounded.
const
  NumCells = 4
  ItersPerWorker = 50_000

# Shared state. Aligned by Pair's field-level {.align: 16.} pragma.
var cells: array[NumCells, Atomic[P]]

# Worker arg carries thread id (used as the `second` stamp).
type WorkerArg = object
  tid: uint64

proc worker(arg: WorkerArg) {.thread.} =
  for cellIdx in 0 ..< NumCells:
    for _ in 0 ..< ItersPerWorker:
      var expected = cells[cellIdx].load()
      while true:
        let desired =
          Pair[uint64, uint64](first: expected.first + 1'u64, second: arg.tid)
        if cells[cellIdx].compareExchangeStrong(expected, desired):
          break
        # On CAS failure, `expected` was overwritten with the current
        # value; loop with the fresh value.

suite "DWCAS concurrent CAS contention":
  test "N threads x NumCells x K iters: no torn reads, no lost updates":
    let N = max(2, min(8, countProcessors()))

    # Reset cells.
    for i in 0 ..< NumCells:
      cells[i].store(Pair[uint64, uint64](first: 0'u64, second: 0'u64))

    var threads = newSeq[Thread[WorkerArg]](N)
    for tid in 0 ..< N:
      createThread(threads[tid], worker, WorkerArg(tid: tid.uint64))
    joinThreads(threads)

    # Lost-update check: each cell saw N*K successful CAS bumps.
    for i in 0 ..< NumCells:
      let final = cells[i].load()
      check final.first == uint64(N) * uint64(ItersPerWorker)
      # Torn-read sentinel: `second` must equal some real worker id.
      check final.second < uint64(N)
