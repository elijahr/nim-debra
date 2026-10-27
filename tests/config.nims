when withDir(thisDir() & "/..", system.fileExists("nimble.paths")):
  include "../nimble.paths"
switch("path", "$projectDir/../src")
