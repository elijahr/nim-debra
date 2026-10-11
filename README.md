# nim-debra (Compatibility Facade)

> [!IMPORTANT]
> ### ⚠️ Package Consolidated into [`lockfree`](https://github.com/elijahr/lockfree)
> **`nim-debra` has been merged into canonical [`lockfree`](https://github.com/elijahr/lockfree) under `lockfree/smr/nebr`.**
>
> All active development, documentation, benchmarks, and SMR engine enhancements take place in **[`lockfree`](https://github.com/elijahr/lockfree)**.
> This repository is maintained strictly as a **zero-overhead backwards-compatibility facade** for existing Nimble packages. New projects should depend directly on `lockfree`.
>
> - 📖 **Canonical Documentation**: [https://elijahr.github.io/lockfree/](https://elijahr.github.io/lockfree/)
> - 📚 **Canonical SMR Documentation**: [https://elijahr.github.io/lockfree/latest/api/smr/nebr/](https://elijahr.github.io/lockfree/latest/api/smr/nebr/)
> - 🔄 **Migration Guide**: [https://elijahr.github.io/lockfree/latest/migrations/from-nim-debra/](https://elijahr.github.io/lockfree/latest/migrations/from-nim-debra/)
> - 📦 **Archived Legacy Docs**: Pre-merger documentation is archived in [`lockfree/docs/legacy/nim-debra/`](https://github.com/elijahr/lockfree/tree/main/docs/legacy/nim-debra).

[![Docs](https://img.shields.io/badge/docs-lockfree-blue.svg)](https://elijahr.github.io/lockfree/latest/)
[![Migration Guide](https://img.shields.io/badge/guide-migration-orange.svg)](https://elijahr.github.io/lockfree/latest/migrations/from-nim-debra/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## What is this package?

`nim-debra` continues to exist on Nimble so that existing projects do not break. Under the hood, version `0.11.0+` forwards all calls directly to `lockfree/smr/nebr` (Neutralization-Enhanced Bounded Reclamation):

```nim
# Existing code continues to compile with zero changes:
import debra

var manager: DebraManager[32, ccMulti]
initDebraManager(manager)

var handle = registerThread(manager)
withPin(handle):
  # Protected epoch critical section
  discard
```

## Legacy API Mapping

All historical types, typestate guards, and signal handlers are 100% supported:

| Legacy Symbol | Modern `lockfree` Equivalent |
| :--- | :--- |
| `DebraManager[MaxThreads, CC]` | `lockfree/smr/nebr.DebraManager` |
| `ThreadHandle[MaxThreads, CC]` | `lockfree/smr/nebr.ThreadHandle` |
| `registerThread(manager)` | `lockfree/smr/nebr.registerThread` |
| `unregisterThread(handle)` | `lockfree/smr/nebr.unregisterThread` |
| `withPin(handle, body)` | `lockfree/smr/nebr.withPin` |
| `retireNode(handle, ptr)` | `lockfree/smr/nebr.retireNode` |
| `reclaimNow(handle)` | `lockfree/smr/nebr.reclaimNow` |
| `neutralizeStalled(...)` | `lockfree/smr/nebr.neutralizeStalled` |

## Upgrading to `lockfree`

To migrate your project to `lockfree`:

```nim
# In your .nimble file:
requires "lockfree >= 0.1.0"
```

```nim
# In your code:
import lockfree/smr/nebr
```

Read the full [Migration Guide](https://elijahr.github.io/lockfree/latest/migrations/from-nim-debra/) and [NEBR Documentation](https://elijahr.github.io/lockfree/latest/api/smr/nebr/).
