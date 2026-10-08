## nim-debra: Backwards-compatibility facade.
##
## Re-exports the NEBR Safe Memory Reclamation engine from lockfree.
## Under the hood, version 0.11.0+ forwards all calls directly to
## lockfree/smr/nebr.

when not compileOption("threads"):
  {.error: "nim-debra requires --threads:on".}

import lockfree/smr/nebr
export nebr
