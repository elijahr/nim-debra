# debra.nimble

# Package

version       = "0.1.2"
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

task test, "Run tests":
  exec "nim c -r --mm:refc --threads:on --path:src -d:testing tests/test.nim"

task testExamples, "Compile and run all example files":
  for file in listFiles("examples"):
    if file.endsWith(".nim"):
      echo "Testing: ", file
      exec "nim c -r --hints:off --threads:on --path:src " & file
  echo "All examples passed!"
