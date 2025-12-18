# debra.nimble

# Package

version       = "0.2.1"
author        = "elijahr <elijahr+debra@gmail.com>"
description   = "DEBRA+ safe memory reclamation for lock-free data structures"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]

# Dependencies

requires "nim >= 2.2.0"
requires "typestates >= 0.2.1"
requires "unittest2 >= 0.2.0"

# Tasks

task test, "Run tests with all memory managers":
  for mm in ["orc", "arc", "refc"]:
    echo "Testing with --mm:" & mm
    exec "nim c -r --mm:" & mm & " --threads:on --path:src -d:testing tests/test.nim"
  echo "All memory managers passed!"

task testExamples, "Compile and run all example files":
  for file in listFiles("examples"):
    if file.endsWith(".nim"):
      echo "Testing: ", file
      exec "nim c -r --hints:off --threads:on --path:src " & file
  echo "All examples passed!"
