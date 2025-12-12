# examples/item_processing.nim
## Item lifecycle typestate for demonstrating typestate composition.
##
## This module defines a simple processing pipeline:
##   Unprocessed -> Processing -> Completed | Failed
##
## Use with lockfree_stack_typestates.nim to see how popped items
## bridge into this processing pipeline.

import typestates

type
  Item*[T] = object
    ## Base type for items in the processing pipeline.
    value*: T

  Unprocessed*[T] = distinct Item[T]
    ## Item just received, not yet being processed.

  Processing*[T] = distinct Item[T]
    ## Item currently being worked on.

  Completed*[T] = distinct Item[T]
    ## Item successfully processed (terminal state).

  Failed*[T] = distinct Item[T]
    ## Item processing failed (terminal state).

typestate Item[T]:
  consumeOnTransition = false
  states Unprocessed[T], Processing[T], Completed[T], Failed[T]
  initial Unprocessed[T]
  terminal Completed[T], Failed[T]
  transitions:
    Unprocessed[T] -> Processing[T]
    Processing[T] -> Completed[T] | Failed[T] as ProcessingResult[T]

# Transition: begin processing an item
proc startProcessing*[T](item: Unprocessed[T]): Processing[T] {.transition.} =
  ## Begin processing an unprocessed item.
  Processing[T](Item[T](item))

# Transition: finish processing with success or failure
proc finish*[T](item: Processing[T], success: bool): ProcessingResult[T] {.transition.} =
  ## Complete processing. Returns Completed on success, Failed otherwise.
  if success:
    ProcessingResult[T] -> Completed[T](Item[T](item))
  else:
    ProcessingResult[T] -> Failed[T](Item[T](item))

# Convenience procs for terminal states
proc complete*[T](item: Processing[T]): Completed[T] {.transition.} =
  ## Mark item as successfully completed.
  Completed[T](Item[T](item))

proc fail*[T](item: Processing[T]): Failed[T] {.transition.} =
  ## Mark item as failed.
  Failed[T](Item[T](item))

when isMainModule:
  # Demonstrate the item processing pipeline
  echo "Item Processing Typestate Demo"
  echo "=============================="
  echo ""

  # Create an unprocessed item
  let raw = Unprocessed[int](Item[int](value: 42))
  echo "1. Created item in Unprocessed state"

  # Start processing
  let inProgress = raw.startProcessing()
  echo "2. Transitioned to Processing state"

  # Finish with success
  let successResult = inProgress.finish(success = true)
  echo "3. Finished processing with success"
  case successResult.kind:
  of pCompleted:
    echo "   -> Result: Completed state"
  of pFailed:
    echo "   -> Result: Failed state (unexpected)"

  echo ""

  # Demo failure path
  let raw2 = Unprocessed[int](Item[int](value: 99))
  let inProgress2 = raw2.startProcessing()
  let failResult = inProgress2.finish(success = false)
  echo "4. Alternative path: finish with failure"
  case failResult.kind:
  of pCompleted:
    echo "   -> Result: Completed state (unexpected)"
  of pFailed:
    echo "   -> Result: Failed state"

  echo ""
  echo "Item processing typestate example completed successfully"
