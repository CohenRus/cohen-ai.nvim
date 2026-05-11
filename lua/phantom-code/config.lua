-- ============================================================
-- Internal defaults (prompts, few-shots, templates)
-- Advanced users only — most setups never need to touch these.
-- ============================================================

local default_prompt_prefix_first = [[
You are an AI code completion engine modeled after Cursor Tab. Your sole function is to predict and complete what the user is most likely to type next, based on all available context.
Core Behavior

Input markers:
- `<contextAfterCursor>`: Context after cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Context before cursor

Analyze everything before and after <cursorPosition> to infer intent.
Return exactly one completion: the single highest-confidence prediction.
The completion must begin exactly at <cursorPosition> — never repeat or echo any surrounding code.
Preserve the user's exact whitespace, indentation style, and newline conventions.
]]

local default_prompt = default_prompt_prefix_first
    .. [[

Note that the user input will be provided in **reverse** order: first the
context after cursor, followed by the context before cursor.
]]

local default_guidelines = [[
Completion Style

Finish the current line or token first: close brackets/parens/quotes, finish the expression, or add at most one short following line when the cursor is clearly mid-statement
Avoid multi-line blobs, whole functions, or large refactors — keep ghost text small and local (roughly one line unless you are only closing a single syntactic unit)
Match the surrounding code's style: naming, brackets, spacing, idioms
In comments or docstrings, add at most a short clause, not full paragraphs
In string literals, complete only the likely immediate fragment

Output Rules

Output the completion text only — no explanation, no markdown fences, no preamble
Do not reproduce any code that already appears before or after <cursorPosition>
Never begin the completion with tokens already present immediately before <cursorPosition> (e.g. a `{` that already ends the current line). Never end the completion with tokens already present immediately after <cursorPosition> (e.g. a closing `}` or `;` on the next line).
End with <endCompletion>
If no confident completion exists, output only <endCompletion>
]]

local default_few_shots = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>]],
    },
    {
        role = 'assistant',
        content = [[
        if (options.uppercase) {
            item = item.toUpperCase();
        }
        result.push(item);
<endCompletion>
]],
    },
}

local default_few_shots_prefix_first = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});]],
    },
    default_few_shots[2],
}

local n_completion_template = '8. Provide at most %d completion items.'

local default_expand_system = [[You are a precise coding assistant. The user selected code and gave an instruction.

Respond ONLY with a single XML document (no markdown fences, no preamble) of this shape:

<phantom_expand>
  <!-- Option A — replace the entire selection: -->
  <replacement>...full new text for the selection...</replacement>

  <!-- Option B — one or more edits inside the selection (line numbers are 1-based; line 1 = first line of the selection): -->
  <!-- <edit startLine="2" endLine="4">new lines replacing those lines</edit> -->

  Use Option B when several localized changes are clearer than one big replacement. You may use multiple <edit> elements; they must not overlap. Prefer Option A for small selections or full rewrites.

  Do not echo the original selected code outside the tags. No explanations outside the XML.
]]

local default_expand_system_generate = [[You are a precise coding assistant. The user wants new code inserted at the cursor (there may be no selected text).

Respond ONLY with a single XML document (no markdown fences, no preamble) of this shape:

<phantom_expand>
  <replacement>...code to insert at the cursor...</replacement>
</phantom_expand>

Prefer concise, idiomatic code that fits the surrounding file. No explanations outside the XML.
]]

local default_expand_user_template = [[File: <filePath>
Language: <fileType>

<referencedContextBlock>
Instruction:
<instruction>

Selected code:
<selectedCode>

Context before selection:
<fileContextBefore>

Context after selection:
<fileContextAfter>
<diagnosticsBlock>]]

local default_expand_system_ask = [[You are a helpful coding assistant. Answer clearly and concisely. You may use short markdown (fenced code blocks) when showing examples. Do not invent file paths or APIs not implied by the context.]]

local default_expand_user_template_ask = [[File: <filePath>
Language: <fileType>

Selected code:
<selectedCode>

Context before selection:
<fileContextBefore>

Context after selection:
<fileContextAfter>
<diagnosticsBlock>

<conversationBlock>

Current question:
<question>]]

-- Placeholders wrapped in {{{ }}} are substituted by make_system_prompt / make_chat_llm_shot.
local default_system_template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}'

local default_fim_prompt = function(context_before_cursor, _, opts)
    local utils = require 'phantom-code.utils'
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()
    local fim_hint = utils.add_fim_completion_instruction_comment()
    opts = opts or {}

    local extra = ''
    local diag = opts.diagnostics_context
    if type(diag) == 'string' and diag ~= '' then
        extra = extra .. '<diagnostics>\n' .. diag .. '\n</diagnostics>\n'
    end

    context_before_cursor = language .. '\n' .. tab .. '\n' .. fim_hint .. '\n' .. extra .. context_before_cursor

    return context_before_cursor
end

local default_fim_suffix = function(_, context_after_cursor, _)
    return context_after_cursor
end

---@class phantom-code.ChatInputExtraInfo
---@field is_incomplete_before boolean
---@field is_incomplete_after boolean
---@field diagnostics_context string

---@alias phantom-code.ChatInputFunction fun(context_before_cursor: string, context_after_cursor: string, opts: phantom-code.ChatInputExtraInfo): string
---@alias phantom-code.FIMTemplateFunction phantom-code.ChatInputFunction

--- Configuration for formatting chat input to the LLM
---@class phantom-code.ChatInput
---@field template string Template string with placeholders for context parts
---@field language phantom-code.ChatInputFunction function to add language comment based on filetype
---@field tab phantom-code.ChatInputFunction function to add indentation style comment
---@field diagnostics phantom-code.ChatInputFunction optional diagnostics block from top-level `diagnostics` settings
---@field context_before_cursor phantom-code.ChatInputFunction function to process text before cursor
---@field context_after_cursor phantom-code.ChatInputFunction function to process text after cursor

---@type phantom-code.ChatInput
local default_chat_input = {
    template = '{{{language}}}\n{{{tab}}}\n{{{diagnostics}}}\n<contextAfterCursor>\n{{{context_after_cursor}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>',
    language = function(_, _, _)
        local utils = require 'phantom-code.utils'
        return utils.add_language_comment()
    end,
    tab = function(_, _, _)
        local utils = require 'phantom-code.utils'
        return utils.add_tab_comment()
    end,
    context_before_cursor = function(context_before_cursor, _, opts)
        if opts.is_incomplete_before then
            local _, rest = context_before_cursor:match '([^\n]*)\n(.*)'
            return rest or context_before_cursor
        end
        return context_before_cursor
    end,
    context_after_cursor = function(_, context_after_cursor, opts)
        if opts.is_incomplete_after then
            local content = context_after_cursor:match '(.*)[\n][^\n]*$'
            return content or context_after_cursor
        end
        return context_after_cursor
    end,
    diagnostics = function(_, _, opts)
        local s = opts.diagnostics_context
        if type(s) ~= 'string' or s == '' then
            return ''
        end
        return '<diagnostics>\n' .. s .. '\n</diagnostics>\n'
    end,
}

---@type phantom-code.ChatInput
local default_chat_input_prefix_first = vim.deepcopy(default_chat_input)
default_chat_input_prefix_first.template =
    '{{{language}}}\n{{{tab}}}\n{{{diagnostics}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}'

-- ============================================================
-- Configuration
-- ============================================================

local M = {
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

    -- Inline ghost text and blink.cmp completion
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
        ---@type (fun(): boolean)[]
        enable_predicates = {},
    },

    -- Expand selection / generate-at-cursor flow
    expand = {
        -- Master switch; set true to enable expand keymaps and commands
        enable = false,

        -- Override top-level provider for expand only; nil = inherit
        provider = nil,

        -- Extra options merged into provider_options[provider] for expand requests
        provider_options = {},

        -- System prompt for implement mode (model must return phantom_expand XML)
        system = default_expand_system,

        -- System prompt for generate-at-cursor when the selection is empty
        system_generate = default_expand_system_generate,

        -- User message template for implement; placeholders: <instruction>, <selectedCode>, etc.
        user_template = default_expand_user_template,

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
        system_ask = default_expand_system_ask,

        -- User message template for ask mode; placeholders: <question>, <conversationBlock>, etc.
        user_template_ask = default_expand_user_template_ask,

        ui = {
            prompt_height = 10,              -- Max height (lines) for the implement prompt float
            prompt_width = 72,               -- Width (columns) for the implement prompt float
            ask_height = 16,                 -- Max height (lines) for the ask float
            ask_width = 80,                  -- Width (columns) for the ask float
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
}

-- ============================================================
-- Exported defaults for advanced overrides
-- ============================================================

M.default_system = {
    template = default_system_template,
    prompt = default_prompt,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_system_prefix_first = {
    template = default_system_template,
    prompt = default_prompt_prefix_first,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_chat_input = default_chat_input
M.default_chat_input_prefix_first = default_chat_input_prefix_first

M.default_few_shots = default_few_shots
M.default_few_shots_prefix_first = default_few_shots_prefix_first

--- Configuration for FIM template
---@class phantom-code.FIMTemplate
---@field prompt phantom-code.FIMTemplateFunction
---@field suffix phantom-code.FIMTemplateFunction | boolean

---@type phantom-code.FIMTemplate
M.default_fim_template = {
    prompt = default_fim_prompt,
    suffix = default_fim_suffix,
}

-- ============================================================
-- Provider defaults
-- ============================================================

M.provider_options = {
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        transform = {},
        get_text_fn = {},
    },
    openai = {
        model = 'gpt-5.4-nano',
        api_key = 'OPENAI_API_KEY',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = M.default_system_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        transform = {},
    },
    claude = {
        max_tokens = 256,
        api_key = 'ANTHROPIC_API_KEY',
        model = 'claude-haiku-4-5',
        end_point = 'https://api.anthropic.com/v1/messages',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        stream = true,
        optional = {
            stop_sequences = nil,
        },
        transform = {},
    },
    openai_compatible = {
        model = 'mistralai/devstral-small',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        api_key = 'OPENROUTER_API_KEY',
        name = 'Openrouter',
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        transform = {},
    },
    gemini = {
        model = 'gemini-2.0-flash',
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        system = M.default_system_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        stream = true,
        optional = {},
        transform = {},
    },
    openai_fim_compatible = {
        model = 'deepseek-chat',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        transform = {},
        get_text_fn = {},
    },
}

return M
