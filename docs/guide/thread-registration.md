# Thread Registration

Understanding thread registration lifecycle in DEBRA+.

## State Machine

![Registration Typestate](../assets/diagrams/registration.svg)

## Overview

Each thread must register with the DEBRA manager before performing pin/unpin operations. Registration allocates a thread slot and provides a handle for all subsequent operations.

## Registration Process

Registration performs several steps:

1. Search for an unused slot in the thread array
2. Claim the slot by setting the thread ID
3. Initialize the slot's epoch and flags
4. Return a handle containing the slot index

## Thread Limits

The manager is created with a compile-time maximum thread count:

```nim
var manager = initDebraManager[64]()  # Support up to 64 threads
```

Attempting to register more threads than the limit will raise `DebraRegistrationError`.

## Multi-Thread Example

The following example demonstrates multiple threads registering and using DEBRA:

```nim
{% include-markdown "../../examples/thread_registration.nim" %}
```

[:material-file-code: View full source](https://github.com/elijahr/nim-debra/blob/main/examples/thread_registration.nim)

## Per-Thread State

Each thread slot maintains:

- **epoch**: Current/pinned epoch
- **pinned**: Is thread in critical section?
- **neutralized**: Neutralization flag
- **threadId**: Thread identifier for signaling
- **limboBags**: Chain of retired objects

## Best Practices

1. **Register once per thread**: Don't register multiple times
2. **Keep handle alive**: Store the handle for the thread's lifetime
3. **Don't share handles**: Each thread needs its own handle
4. **Respect limits**: Don't exceed MaxThreads parameter

## Current Limitations

### Thread Slot Lifetime

Thread slots are held for the thread's lifetime. Once a thread registers, its slot remains occupied until the manager is destroyed. There is currently no explicit deregistration API.

If a thread exits after registration, its slot remains allocated and cannot be reused until the entire manager shuts down. This means the effective thread limit is determined by the peak number of threads that register over the manager's lifetime, not the number of concurrent threads.

**Implication**: Plan your `MaxThreads` parameter based on the total number of threads that will register throughout your application's lifetime, not just the concurrent thread count.

## Troubleshooting

### "Maximum threads already registered"

All slots are occupied. Either:

- Increase `MaxThreads` when creating the manager
- Reduce the total number of threads that register over the application lifetime
- Check for thread leaks or unnecessary thread creation

## Next Steps

- Learn about [pin/unpin lifecycle](pin-unpin.md)
- Understand [retiring objects](retiring-objects.md)
