# phantom-code.nvim documentation

This folder is the **authoritative reference** beyond the project [README](../README.md). Start with [Overview](overview.md), then use [API](api.md) and [Examples](examples.md) as needed. [Implementation](implementation.md) summarizes architecture and dependencies; [Technical reference](technical.md) covers prompts, pipelines, and extension hooks in depth.

## Contents

| Document | What you will find |
| -------- | ------------------ |
| [overview.md](overview.md) | Purpose, mental model, glossary, how inline vs Expand relate |
| [api.md](api.md) | `setup`, user commands, Lua entry points, modules, errors |
| [examples.md](examples.md) | Config recipes, patterns, pitfalls |
| [implementation.md](implementation.md) | Design decisions, dependencies, architecture summary |
| [technical.md](technical.md) | Architecture diagrams, job pools, templates, transforms, events |

## Documentation checklist

Use this when adding or reviewing docs for a feature.

- [x] Explained what this code/feature does
- [x] Documented why it exists and its purpose
- [x] Defined key concepts and terminology
- [x] Documented function/method signatures (Lua public surface)
- [x] Documented parameters and return values
- [x] Included example usage with code snippets
- [x] Documented error handling and edge cases
- [x] Provided architecture overview
- [x] Documented important design decisions
- [x] Included common use cases with full examples
- [x] Documented best practices and patterns
- [x] Documented common pitfalls to avoid
