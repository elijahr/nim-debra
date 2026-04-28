# debra.nimble

# Package

version = "0.4.0"
author = "elijahr <elijahr+debra@gmail.com>"
description = "DEBRA+ safe memory reclamation for lock-free data structures"
license = "MIT"
srcDir = "src"
installExt = @["nim"]

# Dependencies

requires "nim >= 2.2.0"
requires "typestates >= 0.2.1"
requires "unittest2 >= 0.2.0"

# Tasks

task test, "Run tests with all memory managers":
  for mm in ["orc", "arc", "refc"]:
    echo "Testing with --mm:" & mm
    exec "nim c -r --mm:" & mm &
      " --threads:on --path:src -d:testing tests/test.nim"
  echo "Testing C++ backend"
  exec "nim cpp -r --threads:on --path:src -d:testing tests/test.nim"
  # Negative compile-time test: must run via `nim check` because it asserts
  # (via `compiles`) that DSL symbols are NOT reachable from `debra/atomics`
  # alone. Wiring it into `tests/test.nim` would force the DSL to be imported
  # transitively and defeat the test.
  echo "[nim check] verifying tests/t_atomics_dsl_negative.nim - DSL must NOT leak into debra/atomics core"
  exec "nim check --threads:on --hints:off --warnings:off --path:src tests/t_atomics_dsl_negative.nim"
  echo "[nim check] passed: DSL boundary intact"
  echo "All backends passed!"

task testExamples, "Compile and run all example files":
  for file in listFiles("examples"):
    if file.endsWith(".nim"):
      echo "Testing: ", file
      exec "nim c -r --hints:off --threads:on --path:src " & file
  echo "All examples passed!"
