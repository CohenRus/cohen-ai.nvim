# Implementation details

This page is a **high-level** companion to the full [technical reference](technical.md). Read it for orientation; use `technical.md` for prompts, transforms, and step-by-step pipelines.

## Architecture overview

Three cooperating layers:

1. **Configuration** (`lua/phantom-code/config.lua`) — default prompts, templates, provider tables. Merged once in `init.setup`.
2. **Request paths**
   - **Inline:** `virtualtext.lua` and/or `blink.lua` → `utils` (context, diagnostics, import snippets) → `backends/<provider>.complete` → `backends/common.lua` (inline job pool) → callback with candidate strings.
   - **Expand:** `expand.lua` (sessions, floats, keymaps) → `expand_context_refs.lua` → `utils` (file surround, diagnostics) → `backends/<chat>.expand_chat` → parse/merge → `expand_inline_diff.lua`.
3. **Shared infrastructure** — `utils.lua`, `context.lua`, `plenary.job` + `curl` (see `utils.make_curl_args` and backends).

Inline and Expand **never share the same job termination list**, so a long Expand request does not cancel an inline suggestion mid-flight and vice versa.

## Important design decisions

| Decision | Rationale |
| -------- | --------- |
| **Mutually exclusive blink vs virtual-text auto per buffer** | Avoid duplicate or conflicting completion UIs; `blink.enabled()` checks `utils.virtual_text_auto_active()`. |
| **`<endCompletion>` delimiter for inline only** | Chat models need a machine-parsable split; Expand returns XML or plain text, not multiple tab completions. |
| **Expand XML (`phantom_expand`)** | Structured apply + optional `<edit>` ranges reduce whole-buffer mistakes vs raw paste. |
| **Separate ask mode** | Q&A does not share implement message history templates; different system prompt and UI lifecycle (hide/show, notifications). |
| **Suffix-first vs prefix-first chat templates** | Provider defaults in `config.lua` match empirical quality (Claude/OpenRouter default uses suffix-first ordering in the user turn). |
| **Buffer-local `vim.b.phantom_code_virtual_text_auto_trigger`** | Allows `:PhantomCode virtualtext toggle` and filetype-driven behavior without restarting Neovim. |

## Dependencies and integrations

| Dependency | Role |
| ---------- | ---- |
| **[plenary.nvim](https://github.com/nvim-lua/plenary.nvim)** | `plenary.job` for spawning `curl`, async completion. |
| **`curl`** | HTTP(S) to provider APIs; extra args via `curl_extra_args`, proxy via `proxy`. |
| **blink.cmp** (optional) | `phantom-code.blink` source; loaded with `pcall` when present. |
| **nvim-cmp** (optional) | `virtualtext.lua` can suppress ghost text when cmp popup visible (`show_on_completion_menu`). |
| **LSP** | Optional diagnostics in prompts; `@symbol:` references use document symbols. |
| **Neovim 0.10+** | APIs used across buffers, extmarks, `vim.system` / uv timers as applicable. |

## Source file map

Reproduced here for quick navigation; the authoritative table is in [technical.md § File map](technical.md#file-map).

| Module | Responsibility |
| ------ | ---------------- |
| `init.lua` | `setup`, `:PhantomCode`, `change_model` / `change_provider`, `make_blink_map` |
| `config.lua` | Defaults and schema comments |
| `virtualtext.lua` | Ghost text, debounce, accept/dismiss actions |
| `blink.lua` | blink.cmp source protocol |
| `expand.lua` | Sessions, floats, implement + ask |
| `expand_parse.lua` | XML / fallback parsing |
| `expand_inline_diff.lua` | Preview extmarks |
| `expand_context_refs.lua` | `@file` / `@symbol` |
| `context.lua` | Import resolution for inline |
| `utils.lua` | Context slicing, provider resolution, notifications, curl args |
| `modelcard.lua` | Model list for `change_model` UI |
| `backends/*` | Provider-specific HTTP and streaming decode |

## Related

- [overview.md](overview.md) — terminology
- [api.md](api.md) — public Lua API
- [technical.md](technical.md) — full internals
