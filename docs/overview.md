# Overview

## What this project does

**phantom-code.nvim** is a Neovim plugin that sends your buffer context to large language models (LLMs) and surfaces the results in the editor in two main ways:

1. **Inline completion** — Ghost text after the cursor (virtual text) and/or items in **[blink.cmp](https://github.com/Saghen/blink.cmp)**. The model predicts what you are likely to type next; you accept, cycle candidates, or dismiss.
2. **Expand** — You select code (or place the cursor for **generate-at-cursor**), type a natural-language instruction, and the model returns structured XML. The plugin renders an **inline diff** on the buffer; you accept, dismiss, or revise. **Expand ask** is a separate Q&A flow over a selection with a floating buffer and follow-up history.

The plugin is a derivative of **[minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim)** (GPL-3.0) with additional features and documentation paths described here.

## Why it exists

Neovim users who already rely on LSP and treesitter still benefit from **probabilistic** completions and **instruction-driven** edits: models can suggest idioms, boilerplate, or refactors that are not encoded in a language server. phantom-code.nvim focuses on:

- **Low-friction inline** — debounced requests, optional import-aware context, optional diagnostics in the prompt.
- **Controlled Expand** — explicit user instruction, XML-shaped responses, preview before apply.
- **Provider flexibility** — Anthropic Claude, OpenAI, OpenRouter-style chat APIs, or fill-in-the-middle (FIM) endpoints without locking you to one vendor.

## Key concepts and terminology

| Term | Meaning |
| ---- | ------- |
| **Inline** | Tab-style completion: one or more candidate strings terminated with `<endCompletion>` in the model output (chat backends). |
| **Virtual text** | Built-in ghost text drawn with extmarks; toggled per buffer via `inline.virtualtext.auto_trigger_ft` and related options. |
| **blink source** | Lua module `phantom-code.blink` registered as a blink.cmp provider. When virtual-text auto-trigger is active for a buffer, the blink source is **disabled** for that buffer so you do not get duplicate UIs. |
| **Expand (implement)** | Chat request with `expand.system` / `expand.user_template`; model returns `<phantom_expand>` with `<replacement>` and/or `<edit>` blocks. |
| **Generate-at-cursor** | Expand with an empty selection: uses `expand.system_generate` and still expects `<phantom_expand><replacement>…`. |
| **Expand ask** | Separate chat using `expand.system_ask` and `expand.user_template_ask`; no XML apply step — answers are shown in a float. |
| **Context window** | Character budget for text before/after the cursor (inline) or around the selection (Expand file surround), split by `context_ratio`. |
| **FIM** | Fill-in-the-middle: HTTP APIs that take `prompt` + `suffix` instead of a chat transcript (`openai_fim_compatible`). |
| **Chat provider** | Backends that implement `complete` for inline and `expand_chat` for Expand (Claude, OpenAI, `openai_compatible`). FIM-only backends do **not** support Expand. |
| **Job pools** | Separate curl job lists for inline vs Expand so cancelling one flow does not kill the other ([technical.md](technical.md#job-pools-backendscommonlua)). |
| **Revise** | After a proposal is in **review**, send a new instruction while keeping session history capped by `expand.max_conversation_messages`. |
| **Context references** | In Expand instructions, `@file:path` and `@symbol:Name` are stripped from the visible text and merged into the prompt ([technical.md](technical.md) expand section). |

## Requirements

- **Neovim 0.10+**
- **[plenary.nvim](https://github.com/nvim-lua/plenary.nvim)** (jobs / async helpers)
- **`curl`** on `PATH` (or `curl_cmd` pointing to a binary)

## Related reading

- Installation and quick start: [README](../README.md)
- Lua API and commands: [api.md](api.md)
- Recipes and pitfalls: [examples.md](examples.md)
- Architecture and design summary: [implementation.md](implementation.md)
- Prompts, transforms, deep architecture: [technical.md](technical.md)
