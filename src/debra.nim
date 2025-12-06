## nim-debra: DEBRA+ Safe Memory Reclamation
##
## This library provides typestate-enforced epoch-based reclamation
## with signal-based neutralization for lock-free data structures.

when not compileOption("threads"):
  {.error: "nim-debra requires --threads:on".}

# Placeholder - will be populated in subsequent tasks
