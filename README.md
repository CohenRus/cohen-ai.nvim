# phantom-code.nvim

> **Based on [minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim)** by Milan Glacier (GPL-3.0).
> This project is a derivative of minuet-ai.nvim and is distributed under the same **GPL-3.0** license.

AI-powered code completion and rewriting for Neovim. Get inline ghost text suggestions as you type, and rewrite selected code with natural language instructions.

## Documentation

- **[docs/README.md](docs/README.md)** — documentation index and checklist
- **[docs/overview.md](docs/overview.md)** — purpose, concepts, glossary
- **[docs/api.md](docs/api.md)** — `setup`, commands, Lua modules, errors
- **[docs/examples.md](docs/examples.md)** — recipes, practices, pitfalls
- **[docs/implementation.md](docs/implementation.md)** — architecture summary, design decisions, dependencies

## Highlights

- **Inline completion** -- ghost text suggestions appear as you type, powered by any LLM
- **Import-aware context** -- optional snippets from **relative** imports (`require`, `import … from './…'`) are prepended to inline prompts
- **Expand** -- select code (or generate at the cursor), describe what you want, inline diff preview, accept / dismiss / revise
- **Expand ask** -- Q&A over a selection in a non-blocking float; cursor returns to the buffer after you send a question; ask follow-ups via `focus_window` or the ask keybind
- **Multi-provider** -- Claude, OpenAI, OpenRouter, DeepSeek, Ollama, or any OpenAI-compatible API
- **Two completion strategies** -- chat-based (system prompt + context) or fill-in-the-middle (FIM)
- **[blink.cmp](https://github.com/Saghen/blink.cmp) integration** -- popup-menu completions when virtual-text **auto**-trigger is off for the buffer; with `auto_trigger_ft` enabled, phantom-code uses built-in ghost text only for auto inline
- **Diagnostics-aware** -- optionally injects nearby LSP diagnostics into the prompt for smarter suggestions
- **Separate flows** -- inline and Expand use independent job pools so they never cancel each other

## Installation

Requires **Neovim 0.10+**, [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), and `curl`.

```lua
-- lazy.nvim
{
  'CohenRus/phantom-code.nvim',
  dependencies = { 'nvim-lua/plenary.nvim' },
  event = 'InsertEnter',
  opts = {
    provider = 'claude',
    provider_options = {
      claude = {
        api_key = 'ANTHROPIC_API_KEY',
        model = 'claude-haiku-4-5',
      },
    },
    inline = {
      virtualtext = {
        auto_trigger_ft = { '*' },
        keymap = {
          accept = '<Tab>',
          accept_line = '<S-Tab>',
          next = '<M-]>',
          prev = '<M-[>',
          dismiss = '<C-e>',
        },
      },
    },
    expand = {
      enable = true,
      ui = {
        prompt_height = 10,
        prompt_width = 72,
        ask_height = 16,
        ask_width = 80,
        collapsed_marker = ' ⋯ expand', -- eol virt text when UI is collapsed via toggle_window; "" to disable
      }, -- heights are max; windows auto-size
      inline_diff = { enable = true },
      keymap = {
        invoke = '<leader>ae',
        ask = '<leader>aq',
        accept = '<leader>ay',
        dismiss = '<leader>an',
        revise = '<leader>ar',
        focus_window = '<leader>aw',
      },
    },
  },
}
```

Set your API key as an environment variable (e.g. `ANTHROPIC_API_KEY`). The `api_key` field is the **name** of the env var, not the secret itself.

For **blink.cmp**, register the source in your blink config with `module = 'phantom-code.blink'`.

## Usage

### Inline completion

Start typing in insert mode. Ghost text appears after a short debounce. Use your configured keymaps to accept, cycle, or dismiss suggestions.

The plugin sends surrounding code (controlled by `context_window` / `context_ratio`), optional LSP diagnostics, and (by default) **import snippets** from resolved relative imports (`inline.import_context`) to the LLM. Defaults: `inline.debounce = 150` ms, `inline.throttle = 500` ms, `inline.cursor_moved_throttle_ms = 50` (limits how often `CursorMovedI` restarts the debounced request).

### Expand (implement)

1. **Selection:** Select code in visual mode, use `'<` / `'>` from the last visual selection, **or** stay in **normal mode** at the cursor for **generate-at-cursor** (empty selection).
2. Press your invoke keymap (e.g. `<leader>ae`) or run `:PhantomCode expand`.
3. Enter an instruction in the expand float. The float auto-sizes and anchors near the selection when there is room. **Enter** submits in both normal and insert mode; use **Ctrl-J** in insert mode to insert a newline. After you submit, focus returns to the code buffer while the prompt float stays open with a generating/review title.
4. **Context references** (optional): in the instruction, use `@file:relative/or/abs/path` or `@file:"path with spaces"` to inject file contents, and `@symbol:Name` to inject a snippet from **LSP document symbols** (same buffer). Stripped from the visible instruction and merged into the prompt (budget: `expand.max_reference_chars`).
5. The model should return `<phantom_expand>` XML: either `<replacement>...</replacement>` for a full selection replace, or one or more `<edit startLine="N" endLine="M">...</edit>` blocks (lines are 1-based within the selection). If the XML is missing, the plugin falls back to treating the reply as a single replacement.
6. **Inline diff** (Avante-style) is drawn on the buffer over the selection: changed/deleted lines are highlighted; added lines appear as virtual `+` lines. No separate diff popup.
7. Use your keymaps (or commands below): **accept** applies the proposal, **dismiss** cancels (also works **while the model is generating** and from inside expand floats), **focus_window** toggles between the code buffer and the open instruction or ask UI, **revise** opens a new instruction float while keeping the previous diff visible until you submit a new request.

**Revise history:** Each implement turn appends user + assistant messages for the session. Long chains are capped by `expand.max_conversation_messages` (default 16 messages ≈ 8 rounds; set `0` for unlimited).

Expand uses a separate chat request with its own system prompt and context budget, independent from inline completion. **Generate mode** uses `expand.system_generate` when the selection is empty.

### Expand ask

1. Select the code you want the model to see as context
2. Run `:PhantomCode expand ask` or map `expand.keymap.ask`
3. Type your question in the ask buffer (same **Enter** / **Ctrl-J** as implement). The buffer shows only the latest reply or your draft—no transcript headers. History is still sent to the model via the ask template’s conversation block.
4. After you submit, focus moves back to the code buffer; when the assistant returns non-empty text you get a `phantom-code: ask response ready` notification
5. Use `**focus_window`** (or the ask keybind) to jump back into the float for follow-ups; `**focus_window`** again jumps out to the code buffer
6. `**dismiss**` closes the session from the code buffer or from inside the float

## Providers


| Key                     | Strategy | Notes                                                         |
| ----------------------- | -------- | ------------------------------------------------------------- |
| `claude`                | Chat     | Anthropic Messages API                                        |
| `openai`                | Chat     | OpenAI Chat Completions API                                   |
| `openai_compatible`     | Chat     | OpenRouter, Groq, local servers, or any OpenAI-compatible API |
| `openai_fim_compatible` | FIM      | DeepSeek, Ollama `/v1/completions`, or any FIM-compatible API |


You can use different providers for inline and Expand by setting `inline.provider` and `expand.provider` separately.

## Commands

`:PhantomCode` subcommands complete with Tab.


| Command                            | Effect                                                      |
| ---------------------------------- | ----------------------------------------------------------- |
| `:PhantomCode virtualtext enable`  | Enable virtual-text auto-trigger in this buffer             |
| `:PhantomCode virtualtext disable` | Disable auto-trigger in this buffer                         |
| `:PhantomCode virtualtext toggle`  | Toggle auto-trigger in this buffer                          |
| `:PhantomCode blink enable`        | Enable blink auto-complete for phantom-code source          |
| `:PhantomCode blink disable`       | Disable blink auto-complete                                 |
| `:PhantomCode blink toggle`        | Toggle blink auto-complete                                  |
| `:PhantomCode expand`              | Run Expand (implement) using visual marks `'<` `'>`         |
| `:PhantomCode expand ask`          | Expand ask mode (Q&A over selection)                        |
| `:PhantomCode expand accept`       | Accept the current Expand implement proposal (review state) |
| `:PhantomCode expand dismiss`      | Dismiss expand session / clear inline diff                  |
| `:PhantomCode expand revise`       | Revise instruction (implement review state)                 |


## Configuration

Defaults below mirror `lua/phantom-code/config.lua`. **You do not need to paste this whole block** — only override what you want.

For provider entries, `system` / `few_shots` / `chat_input` (chat) and `template` (FIM) are managed by the plugin; only scalar defaults are listed here.

```lua
require('phantom-code').setup({
  -- Backend used when inline.provider / expand.provider are both nil
  provider = 'openai_compatible',

  -- Max characters of buffer context (before + after cursor) sent per request
  context_window = 16000,

  -- Fraction of context_window allocated before the cursor (0.0–1.0; 0.75 = 3:1 ratio)
  context_ratio = 0.75,

  -- Default HTTP timeout in seconds; inline and expand can each override independently
  request_timeout = 3,

  -- Notification verbosity: false | "error" | "warn" | "verbose" | "debug"
  notify = 'warn',

  -- Curl binary name or path
  curl_cmd = 'curl',

  -- Extra arguments appended to every curl invocation
  curl_extra_args = {},

  -- HTTP proxy URL forwarded to curl; nil = no proxy
  proxy = nil,

  -- Nearby LSP diagnostics injected into prompts as additional context
  diagnostics = {
    -- Enable diagnostic injection
    enable = false,
    -- Lines above/below the cursor to scan for diagnostics
    line_radius = 12,
    -- Minimum severity to include (vim.diagnostic.severity.{HINT,INFO,WARN,ERROR})
    min_severity = vim.diagnostic.severity.HINT,
    -- Max characters of diagnostic text appended per prompt
    max_chars = 2048,
  },

  inline = {
    -- Override top-level provider for inline only; nil = inherit
    provider = nil,
    -- Extra options merged into provider_options[provider] for inline requests
    provider_options = {},
    -- Inline system-prompt overrides keyed by provider name
    prompt_overrides = {},

    blink = {
      -- Auto-trigger blink.cmp phantom source (disabled on virtual-text-active buffers)
      enable_auto_complete = true,
    },

    virtualtext = {
      -- Filetypes for ghost text auto-trigger; { '*' } = all, {} = none
      auto_trigger_ft = {},
      -- Filetypes excluded from auto-trigger when auto_trigger_ft is broad
      auto_trigger_ignore_ft = {},

      keymap = {
        accept = nil,         -- Insert full suggestion
        accept_line = nil,    -- Insert first line only
        accept_n_lines = nil, -- Insert N lines (prompts for count)
        accept_word = nil,    -- Insert next word token (opt-in)
        next = nil,           -- Next candidate / manually invoke
        prev = nil,           -- Previous candidate / manually invoke
        dismiss = nil,        -- Clear ghost text
      },

      -- Show ghost text while nvim-cmp or blink popup is open
      show_on_completion_menu = false,
    },

    -- Truncate ghost text to at most this many lines; nil = no limit
    max_lines = nil,
    -- Minimum ms between outgoing inline requests; 0 = no throttle
    throttle = 500,
    -- Delay after typing before sending a request (ms); 0 = off
    debounce = 150,
    -- Minimum ms between CursorMovedI-triggered request restarts; 0 = off
    cursor_moved_throttle_ms = 50,
    -- Cache size for typing-ahead prefix states (virtual text)
    completion_cache_size = 10,

    -- Optional gates that can suppress automatic inline requests
    request_gating = {
      -- Skip auto-request when both the current and previous line are blank
      skip_consecutive_empty_lines = false,
    },

    -- Snippets from resolved relative imports prepended to inline context
    import_context = {
      enable = true,
      max_chars = 4000,         -- Total characters drawn from imported files
      max_files = 3,            -- Maximum import files appended
      max_imports_scanned = 64, -- Import lines scanned per request
    },

    -- Add a single-line duplicate entry for multi-line candidates (cmp/blink only)
    add_single_line_entry = true,
    -- Kept for backward compatibility; inline always requests exactly one candidate
    n_completions = 1,
    -- Trim completion suffix when it overlaps this many chars with post-cursor text
    after_cursor_filter_length = 15,
    -- Trim completion prefix when it overlaps this many chars with pre-cursor text
    before_cursor_filter_length = 2,
    -- Fix brace/overlap artifacts when accepting a suggestion (virtual text + blink)
    normalize_on_accept = true,
    -- Optional function(context, cmp_context) → context called after built-in enrichment
    context_enrich = nil,
    -- Functions called before auto-inline; any returning false suppresses the request
    enable_predicates = {},
  },

  expand = {
    -- Master switch; set true to enable expand keymaps and commands
    enable = false,
    -- Override top-level provider for expand only; nil = inherit
    provider = nil,
    -- Extra options merged into provider_options[provider] for expand requests
    provider_options = {},

    -- System prompt for implement mode (model must return phantom_expand XML)
    system = [[...plugin default, see config.lua...]],
    -- System prompt for generate-at-cursor when the selection is empty
    system_generate = [[...plugin default, see config.lua...]],
    -- User message template; placeholders: <instruction>, <selectedCode>, <referencedContextBlock>, etc.
    user_template = [[...plugin default, see config.lua...]],

    -- Character budget for @file: / @symbol: instruction references
    max_reference_chars = 8000,
    -- Max stored user+assistant message pairs for revise history; 0 = unlimited
    max_conversation_messages = 16,
    -- Extra few-shot messages injected into the implement chat payload
    few_shots = nil,
    -- Diagnostic config deep-merged over top-level diagnostics for expand only
    diagnostics = {},
    -- Override top-level context_window for expand file surround; nil = inherit
    context_window = nil,
    -- Override top-level context_ratio for expand file surround; nil = inherit
    context_ratio = nil,
    -- Override top-level request_timeout for expand HTTP; nil = inherit
    request_timeout = nil,
    -- Cancel in-flight expand jobs when a new expand or dismiss is triggered
    cancel_inflight = true,
    -- Provider-level max_tokens for expand responses; nil = provider default
    max_tokens = nil,
    -- Merge model output with selection using built-in brace/echo rules
    merge = true,
    -- Custom merge: function(selected, response, { bufnr, start_row }) → string
    merge_fn = nil,
    -- Legacy field; implement always uses inline diff regardless of this value
    preview = 'inline_extmark',
    -- Instruction input UI: 'float' = anchored popup, 'input' = vim.ui.input
    prompt_ui = 'float',

    -- System prompt for ask mode
    system_ask = [[...plugin default, see config.lua...]],
    -- User message template for ask mode; placeholders: <question>, <conversationBlock>, etc.
    user_template_ask = [[...plugin default, see config.lua...]],

    ui = {
      prompt_height = 10,             -- Max height (lines) for the implement prompt float
      prompt_width = 72,              -- Width (columns) for the implement prompt float
      ask_height = 16,                -- Max height (lines) for the ask float
      ask_width = 80,                 -- Width (columns) for the ask float
      -- Virtual text shown on the selection row when the expand UI is collapsed; "" = off
      collapsed_marker = ' ⋯ expand',
    },

    inline_diff = {
      -- Draw expand preview as buffer highlights and virtual '+' lines
      enable = true,
    },

    keymap = {
      invoke = nil,        -- Open implement prompt
      ask = nil,           -- Open ask prompt / toggle ask float
      accept = nil,        -- Apply implement proposal (buffer-local)
      accept_global = nil, -- Same as accept but global while in review
      dismiss = nil,       -- Cancel session and clear diff
      revise = nil,        -- Submit a revised instruction
      focus_window = nil,  -- Toggle focus between code buffer and expand UI
      toggle_window = nil, -- Hide or show the expand float
    },
  },

  -- Per-provider defaults (merged with plugin internals; omit any key to use the plugin default)
  provider_options = {
    codestral = {
      model = 'codestral-latest',
      end_point = 'https://codestral.mistral.ai/v1/fim/completions',
      api_key = 'CODESTRAL_API_KEY', -- env var name
      stream = true,
      optional = { stop = nil, max_tokens = nil },
      transform = {},   -- list of request transform functions
      get_text_fn = {}, -- list of functions to extract text from JSON response
    },

    openai = {
      model = 'gpt-5.4-nano',
      api_key = 'OPENAI_API_KEY', -- env var name
      end_point = 'https://api.openai.com/v1/chat/completions',
      stream = true,
      optional = { stop = nil, max_tokens = nil },
      transform = {},
    },

    claude = {
      max_tokens = 256,
      api_key = 'ANTHROPIC_API_KEY', -- env var name
      model = 'claude-haiku-4-5',
      end_point = 'https://api.anthropic.com/v1/messages',
      stream = true,
      optional = { stop_sequences = nil },
      transform = {},
    },

    openai_compatible = {
      model = 'mistralai/devstral-small',
      api_key = 'OPENROUTER_API_KEY', -- env var name
      end_point = 'https://openrouter.ai/api/v1/chat/completions',
      name = 'Openrouter', -- label shown in notifications / model cards
      stream = true,
      optional = { stop = nil, max_tokens = nil },
      transform = {},
    },

    gemini = {
      model = 'gemini-2.0-flash',
      api_key = 'GEMINI_API_KEY', -- env var name
      end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
      stream = true,
      optional = {},
      transform = {},
    },

    openai_fim_compatible = {
      model = 'deepseek-chat',
      end_point = 'https://api.deepseek.com/beta/completions',
      api_key = 'DEEPSEEK_API_KEY', -- env var name
      name = 'Deepseek', -- label shown in notifications / model cards
      stream = true,
      optional = { stop = nil, max_tokens = nil },
      transform = {},
      get_text_fn = {},
    },
  },
})
```

## Highlight groups


| Group                         | Default                  | Purpose                                    |
| ----------------------------- | ------------------------ | ------------------------------------------ |
| `PhantomCodeVirtualText`      | `Comment`                | Inline ghost text                          |
| `BlinkCmpItemKindPhantomCode` | `BlinkCmpItemKind`       | blink.cmp kind color                       |
| `PhantomCodeExpandPulse1`     | `Comment`                | Expand busy pulse A                        |
| `PhantomCodeExpandPulse2`     | `Special`                | Expand busy pulse B                        |
| `PhantomCodeExpandPreview`    | `PhantomCodeVirtualText` | Expand preview text                        |
| `PhantomCodeExpandGenBar`     | `Pmenu`                  | Expand generating status padding           |
| `PhantomCodeExpandGenAccent`  | `DiagnosticInfo`         | Expand generating left rule                |
| `PhantomCodeExpandGenLabel`   | `Title`                  | Expand generating label                    |
| `PhantomCodeExpandGenPrompt`  | `Special`                | Expand generating instruction snippet      |
| `PhantomCodeExpandDiffAdd`    | `DiffAdd`                | Expand inline diff: added line virt text   |
| `PhantomCodeExpandDiffDelete` | `DiffDelete`             | Expand inline diff: deleted line highlight |
| `PhantomCodeExpandDiffChange` | `DiffText`               | Expand inline diff: changed line highlight |


## Events

`User` autocmds fired during requests. `args.data` contains metadata (provider, model, timestamp, etc.).


| Pattern                        | When                      |
| ------------------------------ | ------------------------- |
| `PhantomCodeRequestStartedPre` | Before spawning HTTP jobs |
| `PhantomCodeRequestStarted`    | After each job starts     |
| `PhantomCodeRequestFinished`   | After each job finishes   |


## Advanced

Prompt templates, FIM suffix handling, `transform` pipelines, and job pools are documented in [docs/technical.md](docs/technical.md). For a guided tour of the whole docs set, start at [docs/README.md](docs/README.md).