# API documentation

All paths are relative to the plugin root unless noted. After `setup`, the merged config is available as **`require('phantom-code').config`**.

---

## `require('phantom-code').setup(config?)`

**Purpose:** Merge user `config` with defaults from `lua/phantom-code/config.lua`, then initialize virtual text, Expand, and deprecation helpers.

**Parameters**

| Name | Type | Description |
| ---- | ---- | ----------- |
| `config` | `table?` | Partial options; deep-merged with defaults. |

**Returns:** Nothing.

**Side effects**

- Sets `require('phantom-code').config` to the merged table.
- Calls `require('phantom-code.virtualtext').setup()` and `require('phantom-code.expand').setup()`.
- Registers / refreshes the `:PhantomCode` user command.

**Deprecation:** If you pass `enabled = true` at the top level, it is mapped to `inline.enable_predicates` with a `vim.deprecate` warning — prefer configuring `inline.enable_predicates` explicitly.

**Example**

```lua
require('phantom-code').setup({
  provider = 'claude',
  provider_options = {
    claude = { api_key = 'ANTHROPIC_API_KEY', model = 'claude-haiku-4-5' },
  },
  expand = { enable = true },
})
```

---

## Module table `require('phantom-code')`

| Field / function | Signature | Description |
| ---------------- | --------- | ----------- |
| `config` | `table` | Present after `setup`; merged user + default config. |
| `setup` | `function(config?)` | See above. |
| `make_blink_map` | `function(): table` | Returns a blink keymap handler table that calls `cmp.show { providers = { 'phantom-code' } }`. |
| `change_model` | `function(provider_model?: string)` | With no argument, opens `vim.ui.select` from `modelcard` choices. With `"provider:model"`, sets `config.provider` and `provider_options[provider].model`. |
| `change_provider` | `function(provider: string)` | Sets `config.provider` if `provider_options[provider]` exists. |

**`change_model` / `change_provider` errors:** If `setup` was never called, notifies and returns. Invalid `provider:model` format or unknown provider notifies at ERROR level.

---

## User command `:PhantomCode`

**Signature:** `:PhantomCode <subcommand> [args…]`

**Completion:** Tab-complete walks a small tree (see `init.lua`).

| Invocation | Effect |
| ---------- | ------ |
| `:PhantomCode virtualtext enable\|disable\|toggle` | Buffer-local ghost-text auto-trigger. |
| `:PhantomCode blink enable\|disable\|toggle` | Toggles `inline.blink.enable_auto_complete`. |
| `:PhantomCode expand` | Implement Expand (visual marks or generate-at-cursor). |
| `:PhantomCode expand ask` | Expand ask. |
| `:PhantomCode expand accept\|dismiss\|revise` | Buffer/session actions for implement flow. |
| `:PhantomCode change_model [provider:model]` | Model picker or direct set. |
| `:PhantomCode change_provider <name>` | Switch default provider key. |

If `setup` was not called, every subcommand notifies and exits.

---

## `require('phantom-code.virtualtext')`

**Namespace:** `M.ns_id`, `M.augroup` — used for extmarks and autocommands.

### `M.setup()`

Called from the main `setup`; initializes autocommands and highlight defaults.

### `M.action` — inline ghost-text controls

Use these in custom keymaps when you do not want to rely on `inline.virtualtext.keymap` alone.

| Function | Parameters | Returns | Behavior |
| -------- | ---------- | ------- | -------- |
| `accept` | `(max_lines?, opts?)` | nothing | Inserts current suggestion (or first `max_lines` lines). |
| `accept_line` | none | nothing | Same as `accept(1)`. |
| `accept_n_lines` | none | nothing | Prompts for `n` via `vim.fn.input`, then accepts `n` lines (known cursor quirk: see code FIXME). |
| `accept_word` | none | nothing | Inserts next “word” token from suggestion. |
| `next` | none | nothing | Next candidate or triggers fetch. |
| `prev` | none | nothing | Previous candidate. |
| `dismiss` | none | nothing | Clears ghost text and cancels pending inline jobs. |
| `is_visible` | none | `boolean` | True if the main suggestion extmark exists. |
| `enable_auto_trigger` | none | nothing | Sets `vim.b.phantom_code_virtual_text_auto_trigger = true`. |
| `disable_auto_trigger` | none | nothing | Sets buffer var to `false`. |
| `toggle_auto_trigger` | none | nothing | Toggles buffer var. |

Expand prompt buffers: several actions no-op when `utils.is_expand_prompt_buffer()` is true so you do not corrupt the instruction float.

---

## `require('phantom-code.expand')`

Only registers keymaps when `expand.enable` is true (`M.setup` from main `setup`).

| Function | Parameters | Returns | Notes |
| -------- | ---------- | ------- | ----- |
| `invoke` | `opts?` `{ mode?: 'implement' \| 'ask' }` | nothing | `mode` defaults to `'implement'`. Checks `expand.enable`, API key, chat provider for implement. May call `dismiss_all` when `cancel_inflight`. |
| `invoke_ask` | none | nothing | `invoke { mode = 'ask' }`. |
| `ask_toggle` | none | `boolean` | Hide visible ask float, reopen hidden session, or no-op if no ask session. |
| `ask_dismiss` | none | nothing | Destroys any ask session. |
| `toggle_expand_window_view` | none | nothing | Hide/show implement prompt or ask float (prefers current buffer’s session). |
| `focus_nearest_window` | none | nothing | Focus ask or implement UI for current buffer, else any session; notifies if none. |
| `unfocus_window` | none | `boolean` | If current window is expand UI, jump to source buffer and return `true`. |
| `dismiss` | `session_id?` | nothing | With id: destroy that session. Without: `dismiss_all()`. |
| `accept` | `session_id?` | nothing | Applies **review** proposal; if no id, picks newest eligible implement session. **Warns** on range mismatch; **errors** if `nvim_buf_set_text` fails. |
| `revise` | `session_id?` | nothing | Re-opens prompt from review; empty instruction restores previous proposal. |
| `setup` | none | nothing | Keymaps from `expand.keymap` when `expand.enable`. |

**Edge cases**

- **Multiple implement sessions in review:** `accept` / `revise` without `session_id` sort candidate ids and take the **largest** id (most recent).
- **Expand on FIM-only provider:** `invoke` notifies that a chat provider is required.
- **Accept after buffer edits:** `range_matches_buffer` may abort accept with a warning.

---

## `require('phantom-code.blink')` (blink.cmp source)

Blink expects a source object from `require('phantom-code.blink').new()`.

| Method | Parameters | Returns / callback | Description |
| ------ | ---------- | ------------------ | ----------- |
| `enabled` | `self` | `boolean` | False when expand prompt buffer, when virtual-text auto is active for buffer, when API key missing, or backend unavailable. |
| `new` | none | `source` | Factory for a fresh source instance (debounce / throttle state). |
| `get_completions` | `self, ctx, callback` | calls `callback({ items = … })` or `callback()` | Respects `inline.blink.enable_auto_complete`, `enable_predicates`, throttle, and deduplicates items across callbacks. |

Register in blink config with `module = 'phantom-code.blink'` (see [README](../README.md)).

---

## Configuration shape (high level)

The default table is the single source of truth in `lua/phantom-code/config.lua`. Top-level keys include:

- `provider`, `context_window`, `context_ratio`, `request_timeout`, `notify`, `curl_cmd`, `curl_extra_args`, `proxy`, `diagnostics`
- `inline` — provider overrides, virtual text, blink, throttle/debounce, import context, filters, `context_enrich`, `enable_predicates`
- `expand` — enable flag, templates, ask templates, UI sizes, `inline_diff`, keymaps, merge options
- `provider_options` — per-backend URLs, models, `transform`, `get_text_fn`, streaming flags, etc.

For field-by-field behavior and prompt placeholders, see [technical.md](technical.md) and the comments in `config.lua`.

---

## Notifications and errors

- **`notify`** config: `false \| "error" \| "warn" \| "verbose" \| "debug"` — controls internal `vim.notify` verbosity where implemented.
- **HTTP failures:** Inline callbacks may receive no arguments; virtual text / blink clear or skip items depending on path (see backend `complete` implementations).
- **Missing API key:** `utils.get_api_key` failures surface as user-visible notifies on Expand invoke and blink `enabled` false.

---

## Autocmd events

`User` autocmd patterns and `args.data` (`phantom-code.EventData`) are documented in [technical.md § Events reference](technical.md#events-reference).

---

## Further reading

- [overview.md](overview.md) — terminology
- [examples.md](examples.md) — config patterns
- [implementation.md](implementation.md) — architecture summary
- [technical.md](technical.md) — `complete` vs `expand_chat`, templates, job pools
