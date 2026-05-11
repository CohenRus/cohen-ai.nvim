# Examples, practices, and pitfalls

## Common use cases

### Ghost text on all filetypes

```lua
require('phantom-code').setup({
  inline = {
    virtualtext = {
      auto_trigger_ft = { '*' },
      keymap = {
        accept = '<Tab>',
        dismiss = '<C-e>',
        next = '<M-]>',
        prev = '<M-[>',
      },
    },
  },
})
```

### blink.cmp only where virtual text is off

Keep `auto_trigger_ft` narrow (or `{}`) and register `module = 'phantom-code.blink'` in blink. Optionally use `make_blink_map()` for a manual trigger key.

```lua
-- blink keymap snippet
['<C-x>'] = require('phantom-code').make_blink_map(),
```

### Different models for inline vs Expand

```lua
require('phantom-code').setup({
  provider = 'openai_compatible',
  inline = {
    provider = 'openai_fim_compatible',
    provider_options = {
      openai_fim_compatible = {
        end_point = 'http://127.0.0.1:11434/v1/completions',
        model = 'qwen2.5-coder',
        api_key = 'OLLAMA_API_KEY', -- often unused locally
      },
    },
  },
  expand = {
    enable = true,
    provider = 'openai_compatible',
    provider_options = {
      openai_compatible = {
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        model = 'anthropic/claude-3.5-haiku',
        api_key = 'OPENROUTER_API_KEY',
      },
    },
  },
})
```

Remember: **Expand requires a chat backend** with `expand_chat`; FIM-only inline is fine alongside chat Expand.

### Skip auto-inline in prose or huge buffers

```lua
require('phantom-code').setup({
  inline = {
    enable_predicates = {
      function()
        return vim.bo.ft ~= 'markdown' and vim.bo.ft ~= 'text'
      end,
      function()
        return vim.fn.line('$') < 8000
      end,
    },
  },
})
```

Predicates run on the hot path when auto-trigger is on — keep them **fast**.

### Append custom context (branch name)

```lua
require('phantom-code').setup({
  inline = {
    context_enrich = function(context, _)
      local branch = vim.trim(vim.fn.system { 'git', 'branch', '--show-current' })
      if branch ~= '' then
        context.lines_before = ('-- git: %s\n'):format(branch) .. context.lines_before
      end
      return context
    end,
  },
})
```

Returning a **new** table replaces the whole context; returning `nil` leaves it unchanged (see [technical.md](technical.md#context-enrichment)).

---

## Best practices

1. **Set API keys via environment variables** — store the **name** of the env var in `api_key`, not the secret literal, and export vars in your shell or secrets manager.
2. **Tune FIM `max_tokens`** for shorter ghost text when the model runs away ([technical.md § FIM](technical.md#fim-providers-openai_fim_compatible-codestral-shaped-apis)).
3. **Use `expand.cancel_inflight`** (default `true`) unless you intentionally want overlapping Expand HTTP jobs; when `false`, dismissal uses per-session job termination.
4. **Match provider to endpoint** — OpenAI *chat* URLs do not speak raw FIM; point `openai_fim_compatible` at a completions/FIM endpoint.
5. **Status / UX hooks** — subscribe to `User PhantomCodeRequestStarted` / `Finished` for statusline spinners ([technical.md § Events](technical.md#events-reference)).

---

## Common pitfalls

| Pitfall | What goes wrong | Mitigation |
| ------- | ---------------- | ---------- |
| **FIM provider for Expand** | `invoke` errors: Expand needs `expand_chat`. | Set `expand.provider` to `claude`, `openai`, or `openai_compatible`. |
| **Both blink and virtual text auto on same buffer** | Plugin disables blink on those buffers by design. | Expect one UI; adjust `auto_trigger_ft` or blink registration. |
| **Editing the buffer during Expand review** | Accept may warn about range mismatch. | Accept or dismiss before large structural edits, or dismiss and re-run Expand. |
| **Diagnostics + FIM** | Model may echo errors as comments. | Toggle `diagnostics.enable` or narrow `line_radius` / `max_chars`. |
| **Ollama `num_ctx` in `optional`** | Silently ignored on OpenAI-compatible completions route. | Bake context into a Modelfile ([technical.md § Ollama](technical.md#ollama--optional-field-behavior)). |
| **Heavy `enable_predicates`** | Typing latency with auto inline. | Keep predicates O(1) and allocation-free. |
| **Assuming `change_model` lists every model** | List comes from `modelcard.lua` and configured subprovider name. | For custom models, set `provider_options.<p>.model` directly in config. |

---

## Expand instruction examples

**Full replacement (conceptual):** the model returns:

```xml
<phantom_expand>
  <replacement>-- new block replacing entire selection</replacement>
</phantom_expand>
```

**Localized edits:**

```xml
<phantom_expand>
  <edit startLine="2" endLine="4">  fixed_body_here
</edit>
</phantom_expand>
```

Line numbers are **1-based within the selection**. If XML is missing, the plugin treats the whole reply as a single replacement (see [technical.md](technical.md)).

---

## Where to go next

- [api.md](api.md) — exact Lua entry points
- [implementation.md](implementation.md) — design decisions at a glance
- [technical.md](technical.md) — transforms, templates, job pools, float behavior
- [overview.md](overview.md) — glossary
