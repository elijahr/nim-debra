# Getting Started

This guide walks through setting up and using nim-debra in your lock-free data structures.

## Installation

Add nim-debra to your `.nimble` file:

```nim
requires "debra >= 0.1.0"
```

Or install globally:

```bash
nimble install debra
```

## Basic Usage

The following example demonstrates the complete DEBRA+ lifecycle:

1. Initialize the manager
2. Register the thread
3. Pin/unpin critical sections
4. Retire objects for later reclamation
5. Periodically reclaim memory

```nim
{% include-markdown "../../examples/basic_usage.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/basic_usage.nim)

## Key Concepts

- **Manager**: Coordinates epoch-based reclamation across threads
- **Handle**: Per-thread registration for DEBRA operations
- **Pin/Unpin**: Mark critical sections where shared data is accessed
- **Managed[T]**: Wrapper type that prevents GC from collecting objects until retired
- **Retire**: Mark removed objects for later safe reclamation
- **Reclaim**: Free objects when all threads have advanced past their epoch

## Next Steps

- Learn about [DEBRA+ concepts](concepts.md)
- Understand [thread registration](thread-registration.md)
- Deep dive into [retiring objects](retiring-objects.md)
