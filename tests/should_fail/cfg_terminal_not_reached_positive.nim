## Self-contained CFG-analyzer fixture (positive case).
##
## Demonstrates the typestates 0.9.0+ CFG analyzer accepts a proc where
## every exit path reaches a terminal state.
##
## The fixture is local to this test file because typestates only walks
## `{.transition.}`-registered procs declared in the typestate's home
## module. nim-debra's EBR typestates live in nim-debra's source
## modules, so user test code cannot register transitions against
## them. The MyFSM typestate below mirrors typestates' own
## `tests/should_fail/pragmas/cfg_analyzer_early_return_misses_terminal.nim`
## fixture shape.
##
## Must `nim c` cleanly.

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

proc good*[N: static int](
    m: sink Middle[N], flag: bool
): Done[N] {.transition, raises: [].} =
  ## Every exit returns a Done value; the CFG analyzer accepts.
  if flag:
    result = step2(m)
    return
  result = step2(m)

verifyTypestates()
