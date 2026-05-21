## Self-contained CFG-analyzer fixture (negative case).
##
## Demonstrates the typestates 0.9.0+ CFG analyzer rejects a proc where
## at least one exit path leaves a typestate-bearing local in a
## non-terminal state.
##
## Must NOT compile. The runner pins the substring
## "has not reached a terminal state at this return" — typestates'
## `validateExitEdge` (verify.nim) emits this message when a tracked
## local hasn't been driven to a terminal state by the exit edge and
## no destructorTransition is registered for its current state.
##
## See cfg_terminal_not_reached_positive.nim for the rationale behind
## using a local fixture instead of nim-debra's EBR typestates.

import typestates

type
  MyFSM*[N: static int] = object of RootObj

  Start*[N: static int] = distinct MyFSM[N]
  Middle*[N: static int] = distinct MyFSM[N]
  Done*[N: static int] = distinct MyFSM[N]

typestate MyFSM[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false
  strictTransitions = false
  states:
    Start[N]
    Middle[N]
    Done[N]
  initial:
    Start[N]
  terminal:
    Done[N]
  transitions:
    Start[N] -> Middle[N]
    Middle[N] -> Done[N]

proc step1*[N: static int](s: sink Start[N]): Middle[N] {.transition, raises: [].} =
  Middle[N](MyFSM[N](s))

proc step2*[N: static int](m: sink Middle[N]): Done[N] {.transition, raises: [].} =
  Done[N](MyFSM[N](m))

proc badEarlyReturn*[N: static int](
    s: sink Start[N], flag: bool
): Middle[N] {.transition, raises: [].} =
  ## The body-local `m: Middle[N]` is non-terminal at the early return
  ## on the `flag=true` branch — CFG-001 fires there.
  var m {.used.}: Middle[N]
  if flag:
    result = step1(s)
    return # m: Middle[N] non-terminal at this return
  result = step1(s)
  m = step2(result).Middle[N]

verifyTypestates()
