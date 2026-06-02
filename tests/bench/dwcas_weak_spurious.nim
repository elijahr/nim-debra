## tests/bench/dwcas_weak_spurious.nim
##
## DWCAS weak-CAS spurious-failure micro-bench (impl plan Task 27,
## design §8.7).
##
## Measures the rate at which `compareExchangeWeak` on `Atomic[Pair[A, B]]`
## fails when the in-memory value actually equals `expected` at the time
## of the CAS attempt. On x86_64 (`cmpxchg16b`) the rate is structurally
## zero — weak and strong are identical instructions. On aarch64 LL/SC
## (without LSE atomics, or with a backend that maps DWCAS to a casp/ldxp+
## stxp pair) spurious failures can occur when an unrelated cache line
## event invalidates the exclusive reservation between the load and store.
##
## A spurious failure here is detected by re-reading `loc` immediately
## after a CAS-weak failure; if the re-read still matches the `expected`
## the caller passed in, the failure was spurious (the location did not
## actually change between read and CAS). False positives are possible if
## another thread changed `loc` and changed it back between our CAS-fail
## and our re-read (a classic ABA), so the measured rate is an *upper
## bound* on true spurious-failure rate. That is acceptable for the
## threshold check.
##
## Per impl plan: if spurious_rate > 5% on aarch64 LL/SC, recommend
## switching hot paths to `compareExchangeStrong`. On x86_64 the rate
## should be ~0%; treat any non-zero value as a measurement artifact.
##
## Build & run:
##
##   nim r --threads:on --mm:arc --path:src \
##     tests/bench/dwcas_weak_spurious.nim
##
## Output is parsable:
##
##   RESULT: spurious_rate=N.NN% on <platform> (attempts=A failures=F spurious=S)
##   RECOMMENDATION: <use Strong on aarch64 hot paths | Weak is fine>

import std/[random, strformat, times]

import debra/atomics

type
  P = Pair[uint64, uint64]
  WorkerArg = object
    tid: uint64
    seed: int64

const
  NumThreads = 4
  NumCells = 8
  ItersPerThread = 100_000
  SpuriousThresholdPct = 5.0

var
  cells: array[NumCells, Atomic[P]]
  totalAttempts: Atomic[uint64]
  totalFailures: Atomic[uint64]
  totalSpurious: Atomic[uint64]

proc worker(arg: WorkerArg) {.thread.} =
  var rng = initRand(arg.seed)
  var attempts: uint64 = 0
  var failures: uint64 = 0
  var spurious: uint64 = 0
  dwcasOrderRelaxedCAS:
    for _ in 0 ..< ItersPerThread:
      let cellIdx = rng.rand(NumCells - 1)
      var expected = cells[cellIdx].load(moRelaxed)
      let desired = Pair[uint64, uint64](
        first: expected.first + 1'u64, second: arg.tid
      )
      inc attempts
      let ok = cells[cellIdx].compareExchangeWeak(
        expected, desired, moRelease, moRelaxed
      )
      if not ok:
        inc failures
        # Re-read to detect spurious failure: if the current value still
        # equals the expected we observed pre-CAS, the CAS failed without
        # any visible change in `loc`. This over-counts in the presence
        # of ABA (loc changed and was changed back between CAS-fail and
        # re-read), but the upper bound is sufficient for the 5%
        # threshold.
        let postFail = cells[cellIdx].load(moRelaxed)
        if postFail.first == expected.first and
            postFail.second == expected.second:
          inc spurious
  discard totalAttempts.fetchAdd(attempts, moRelaxed)
  discard totalFailures.fetchAdd(failures, moRelaxed)
  discard totalSpurious.fetchAdd(spurious, moRelaxed)

proc platformLabel(): string =
  when defined(macosx) and defined(arm64):
    "macos-arm64"
  elif defined(macosx):
    "macos-x86_64"
  elif defined(linux) and defined(arm64):
    "linux-arm64"
  elif defined(linux):
    "linux-x86_64"
  else:
    "unknown"

proc isAarch64Llsc(): bool =
  # aarch64 without LSE atomics; we cannot detect LSE at runtime here, so
  # treat any aarch64 build as potentially LL/SC for the recommendation.
  # macOS arm64 (Apple Silicon) has LSE (FEAT_LSE) since the M1, so DWCAS
  # may compile to a casp / ldxp+stxp depending on the backend. Surface
  # the rate; let the operator decide.
  when defined(arm64):
    true
  else:
    false

proc main() =
  # Initialize cells with distinct values so each thread observes a real
  # pre-state instead of all-zero.
  for i in 0 ..< NumCells:
    dwcasOrderRelaxedCAS:
      cells[i].store(
        Pair[uint64, uint64](first: 0'u64, second: 0'u64), moRelaxed
      )
  totalAttempts.store(0'u64, moRelaxed)
  totalFailures.store(0'u64, moRelaxed)
  totalSpurious.store(0'u64, moRelaxed)

  var threads: array[NumThreads, Thread[WorkerArg]]
  let t0 = epochTime()
  for i in 0 ..< NumThreads:
    createThread(
      threads[i],
      worker,
      WorkerArg(tid: uint64(i), seed: int64(0xC0FFEE) + int64(i)),
    )
  joinThreads(threads)
  let elapsed = epochTime() - t0

  let attempts = totalAttempts.load(moRelaxed)
  let failures = totalFailures.load(moRelaxed)
  let spurious = totalSpurious.load(moRelaxed)
  let spuriousPct =
    if attempts == 0:
      0.0
    else:
      100.0 * float(spurious) / float(attempts)
  let failurePct =
    if attempts == 0:
      0.0
    else:
      100.0 * float(failures) / float(attempts)
  let platform = platformLabel()

  echo &"RESULT: spurious_rate={spuriousPct:.4f}% on {platform} " &
    &"(attempts={attempts} failures={failures} spurious={spurious} " &
    &"failure_rate={failurePct:.4f}% wallclock={elapsed:.3f}s)"

  if isAarch64Llsc() and spuriousPct > SpuriousThresholdPct:
    echo &"RECOMMENDATION: spurious_rate {spuriousPct:.4f}% exceeds " &
      &"threshold {SpuriousThresholdPct:.2f}% on aarch64 — prefer " &
      "compareExchangeStrong on DWCAS hot paths."
  else:
    echo "RECOMMENDATION: compareExchangeWeak is acceptable on this " &
      "platform (rate within threshold or non-aarch64)."

when isMainModule:
  main()
