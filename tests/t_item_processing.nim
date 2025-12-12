# tests/t_item_processing.nim
## Tests for item_processing typestate example

import unittest2
import ../examples/item_processing

suite "Item Processing Typestate":
  test "Unprocessed -> Processing transition":
    # Create an unprocessed item
    let raw = Unprocessed[int](Item[int](value: 42))

    # Transition to Processing
    let processing = raw.startProcessing()

    # Verify we can access the value through the base type
    check Item[int](processing).value == 42

  test "Processing -> Completed transition (success path)":
    let raw = Unprocessed[string](Item[string](value: "test"))
    let processing = raw.startProcessing()

    # Finish with success
    let result = processing.finish(success = true)

    # Verify it's completed
    case result.kind:
    of pCompleted:
      check Item[string](result.completed).value == "test"
    of pFailed:
      checkpoint "Expected Completed but got Failed"
      check false

  test "Processing -> Failed transition (failure path)":
    let raw = Unprocessed[string](Item[string](value: "test"))
    let processing = raw.startProcessing()

    # Finish with failure
    let result = processing.finish(success = false)

    # Verify it's failed
    case result.kind:
    of pCompleted:
      checkpoint "Expected Failed but got Completed"
      check false
    of pFailed:
      check Item[string](result.failed).value == "test"

  test "complete() convenience method":
    let raw = Unprocessed[int](Item[int](value: 99))
    let processing = raw.startProcessing()

    # Use complete() convenience method
    let completed = processing.complete()

    # Verify state
    check Item[int](completed).value == 99

  test "fail() convenience method":
    let raw = Unprocessed[int](Item[int](value: 99))
    let processing = raw.startProcessing()

    # Use fail() convenience method (from item_processing module)
    let failedItem = item_processing.fail(processing)

    # Verify state
    check Item[int](failedItem).value == 99

  test "full pipeline: Unprocessed -> Processing -> Completed":
    # Create item
    let unprocessed = Unprocessed[int](Item[int](value: 123))

    # Start processing
    let processing = unprocessed.startProcessing()
    check Item[int](processing).value == 123

    # Complete successfully
    let completed = processing.complete()
    check Item[int](completed).value == 123

  test "full pipeline: Unprocessed -> Processing -> Failed":
    # Create item
    let unprocessed = Unprocessed[int](Item[int](value: 456))

    # Start processing
    let processing = unprocessed.startProcessing()
    check Item[int](processing).value == 456

    # Fail using module-qualified call
    let failedItem = item_processing.fail(processing)
    check Item[int](failedItem).value == 456

  test "works with custom types":
    type
      CustomData = object
        id: int
        name: string

    let data = CustomData(id: 1, name: "test")
    let unprocessed = Unprocessed[CustomData](Item[CustomData](value: data))

    # Process to completion
    let processing = unprocessed.startProcessing()
    let result = processing.finish(success = true)

    case result.kind:
    of pCompleted:
      let completedData = Item[CustomData](result.completed).value
      check completedData.id == 1
      check completedData.name == "test"
    of pFailed:
      checkpoint "Expected completed"
      check false
