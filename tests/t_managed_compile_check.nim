## Compile-time check that Managed[ref T] errors on arc/orc without opt-out flag.
##
## This test is designed to FAIL compilation when run with --mm:arc or --mm:orc.
## It should PASS compilation with --mm:refc or with -d:allowSpinlockManagedRef.

import ../src/debra/managed

type
  Node = ref object
    value: int

# This should trigger compile error on arc/orc
let node = Node(value: 42)
let m = managed(node)

echo "If you see this, either you're on refc or used -d:allowSpinlockManagedRef"
