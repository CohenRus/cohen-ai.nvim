-- referenced from copilot.lua https://github.com/zbirenbaum/copilot.lua
local M = {}
local utils = require 'phantom-code.utils'
local api = vim.api
local uv = vim.uv or vim.loop

M.ns_id = api.nvim_create_namespace 'phantom-code.virtualtext'
M.augroup = api.nvim_create_augroup('PhantomCodeVirtualText', { clear = true })

if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeVirtualText' })) then
    api.nvim_set_hl(0, 'PhantomCodeVirtualText', { link = 'Comment' })
end

local internal = {
    augroup = M.augroup,
    ns_id = M.ns_id,
    extmark_id = 1,

    timer = nil,
    context = {},
    is_on_throttle = false,
    current_completion_timestamp = 0,
    last_cursor_moved_schedule_ms = 0,
}

local function should_auto_trigger()
    return vim.b.phantom_code_virtual_text_auto_trigger
end

local has_cmp, cmp = pcall(require, 'cmp')
if not has_cmp then
    cmp = nil
end

local has_blink, blink = pcall(require, 'blink.cmp')
if not has_blink then
    blink = nil
end

local function completion_menu_visible()
    if not has_cmp and package.loaded.cmp then
        has_cmp, cmp = pcall(require, 'cmp')
    end
    if not has_blink and package.loaded['blink.cmp'] then
        has_blink, blink = pcall(require, 'blink.cmp')
    end

    local cmp_visible = false
    if has_cmp and cmp and cmp.core and cmp.core.view and cmp.core.view.visible then
        local ok, visible = pcall(cmp.core.view.visible, cmp.core.view)
        cmp_visible = ok and visible or false
    end

    local blink_visible = false
    if has_blink and blink and blink.is_visible then
        local ok, visible = pcall(blink.is_visible)
        blink_visible = ok and visible or false
    end

    return vim.fn.pumvisible() == 1 or cmp_visible or blink_visible
end

---@param bufnr? integer
---@return phantom-code.VirtualtextSuggestionContext
local function get_ctx(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local ctx = internal.context[bufnr]
    if not ctx then
        ctx = {}
        internal.context[bufnr] = ctx
    end
    return ctx
end

--- Text from buffer start to cursor (byte columns), same shape as `nvim_win_get_cursor`.
---@param bufnr integer
---@param cursor integer[] 1-based [line, col0_byte]
---@return string
local function get_cursor_prefix(bufnr, cursor)
    if not api.nvim_buf_is_valid(bufnr) then
        return ''
    end
    local prefix = api.nvim_buf_get_text(bufnr, 0, 0, cursor[1], cursor[2], {})
    return table.concat(prefix, '\n')
end

-- Maximum bytes stored and compared per cache entry. Keeps cache memory bounded
-- and makes str_startswith comparisons O(512) instead of O(file_size).
local COMPLETION_CACHE_PREFIX_TAIL = 512

--- Cheap variant for the CursorMovedI hot-path: fetches only the lines close to
--- the cursor and returns at most COMPLETION_CACHE_PREFIX_TAIL bytes.
---@param bufnr integer
---@param cursor integer[] 1-based [row, col0_byte]
---@return string
local function get_cursor_prefix_tail(bufnr, cursor)
    if not api.nvim_buf_is_valid(bufnr) then
        return ''
    end
    local row1, col = cursor[1], cursor[2]
    local lines_needed = math.ceil(COMPLETION_CACHE_PREFIX_TAIL / 40) + 2
    local start_row0 = math.max(0, row1 - 1 - lines_needed)
    local prev = api.nvim_buf_get_lines(bufnr, start_row0, row1 - 1, false)
    local cur_line = (api.nvim_buf_get_lines(bufnr, row1 - 1, row1, false)[1] or ''):sub(1, col)
    table.insert(prev, cur_line)
    local prefix = table.concat(prev, '\n')
    if #prefix > COMPLETION_CACHE_PREFIX_TAIL then
        return prefix:sub(-COMPLETION_CACHE_PREFIX_TAIL)
    end
    return prefix
end

---@param s string
---@param prefix string
---@return boolean
local function str_startswith(s, prefix)
    if prefix == '' then
        return true
    end
    return s:sub(1, #prefix) == prefix
end

---@param suggestions string[]
---@param typed_ahead string
---@return string[]
local function strip_typed_prefix(suggestions, typed_ahead)
    if typed_ahead == '' then
        -- Strings are immutable in Lua; a shallow copy is sufficient here.
        local copy = {}
        for i = 1, #suggestions do
            copy[i] = suggestions[i]
        end
        return copy
    end
    local out = {}
    for _, s in ipairs(suggestions) do
        if type(s) == 'string' and str_startswith(s, typed_ahead) then
            table.insert(out, s:sub(#typed_ahead + 1))
        end
    end
    return out
end

---@param ctx phantom-code.VirtualtextSuggestionContext
---@param current_prefix string
---@return boolean True when a cached completion was applied (no HTTP needed).
local function try_completion_cache(ctx, current_prefix)
    local cache = ctx.completion_cache
    if not cache or #cache == 0 then
        return false
    end
    local best_prefix_len = -1
    local best_suggestions = nil
    for i = #cache, 1, -1 do
        local entry = cache[i]
        if str_startswith(current_prefix, entry.prefix) then
            local typed_ahead = current_prefix:sub(#entry.prefix + 1)
            local surviving = strip_typed_prefix(entry.suggestions, typed_ahead)
            local nonempty = false
            for _, s in ipairs(surviving) do
                if type(s) == 'string' and s ~= '' then
                    nonempty = true
                    break
                end
            end
            if nonempty and #entry.prefix >= best_prefix_len then
                best_prefix_len = #entry.prefix
                best_suggestions = surviving
            end
        end
    end
    if not best_suggestions then
        return false
    end
    ctx.suggestions = best_suggestions
    ctx.choice = 1
    ctx.shown_choices = {}
    -- Drop late HTTP completions that were in flight for an older prefix.
    internal.current_completion_timestamp = math.max(uv.now(), internal.current_completion_timestamp + 1)
    update_preview(ctx)
    stop_timer()
    return true
end

---@param ctx phantom-code.VirtualtextSuggestionContext
---@param prefix string
---@param suggestions string[]
local function push_completion_cache(ctx, prefix, suggestions)
    if not prefix or not suggestions or #suggestions == 0 then
        return
    end
    local sz = require('phantom-code').config.inline.completion_cache_size or 10
    ctx.completion_cache = ctx.completion_cache or {}
    -- Truncate to a bounded tail so stored strings stay small regardless of file size.
    local key = #prefix > COMPLETION_CACHE_PREFIX_TAIL and prefix:sub(-COMPLETION_CACHE_PREFIX_TAIL) or prefix
    local sug_copy = {}
    for i = 1, #suggestions do
        sug_copy[i] = suggestions[i]
    end
    table.insert(ctx.completion_cache, { prefix = key, suggestions = sug_copy })
    if #ctx.completion_cache > sz then
        table.remove(ctx.completion_cache, 1)
    end
end

---@param s string
---@return string
local function trim_suggestion_filter(s)
    return (s:gsub('^%s*(.-)%s*$', '%1'))
end

--- Drop ghost suggestions that would be “inactive” on an empty line (Supermaven-style).
---@param data string[]
---@param cursor_before_line string
---@return string[]
local function filter_inactive_blank_line_suggestions(data, cursor_before_line)
    if not data then
        return data
    end
    local lb = trim_suggestion_filter(cursor_before_line or '')
    local filtered = {}
    for _, item in ipairs(data) do
        if type(item) ~= 'string' then
            table.insert(filtered, item)
        else
            local first_line = (vim.split(item, '\n', { plain = true })[1]) or ''
            local inactive = item ~= ''
                and item:sub(1, 1):match '%s'
                and lb == ''
                and trim_suggestion_filter(first_line) ~= ''
            if not inactive then
                table.insert(filtered, item)
            end
        end
    end
    return filtered
end

---@return string[]?
local function get_last_typed_text(ctx)
    ctx = ctx or get_ctx()
    local last_typed = nil
    local last_pos = ctx.last_pos
    if not last_pos then
        return { '' }
    end

    local current_pos = api.nvim_win_get_cursor(0)

    -- Convert 1-based line to 0-based for nvim_buf_get_text
    local start_row = last_pos[1] - 1
    local start_col = last_pos[2]
    local end_row = current_pos[1] - 1
    local end_col = current_pos[2]

    if start_row < end_row or (start_row == end_row and start_col <= end_col) then
        last_typed = api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
    end

    return last_typed
end

---@class phantom-code.VirtualtextSuggestionContext
---@field suggestions? string[]
---@field choice? integer
---@field shown_choices? table<string, true>
---@field last_pos integer[]
---@field preview_anchor? integer[] 0-based row, byte col where inline preview is anchored (for accept)
---@field last_changedtick? integer Last buf_get_changedtick value used for CursorMovedI change-gate
---@field completion_cache? { prefix: string, suggestions: string[] }[]
---@field is_floating? boolean True when ghost uses EOL overlay (trailing text on line)

---@param ctx phantom-code.VirtualtextSuggestionContext
local function reset_ctx(ctx)
    ctx.suggestions = nil
    ctx.choice = nil
    ctx.shown_choices = nil
    ctx.last_pos = nil
    ctx.preview_anchor = nil
    ctx.last_changedtick = nil
    ctx.completion_cache = nil
    ctx.is_floating = nil
end

local function stop_timer()
    if internal.timer and not internal.timer:is_closing() then
        internal.timer:stop()
        internal.timer:close()
        internal.timer = nil
    end
end

---@param bufnr? integer
local function clear_preview(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    pcall(api.nvim_buf_del_extmark, bufnr, internal.ns_id, internal.extmark_id)
end

---@param ctx? phantom-code.VirtualtextSuggestionContext
local function get_current_suggestion(ctx)
    ctx = ctx or get_ctx()

    local ok, choice = pcall(function()
        if not vim.fn.mode():match '^[iR]' or not ctx.suggestions or #ctx.suggestions == 0 then
            return nil
        end

        local choice = ctx.suggestions[ctx.choice]

        return choice
    end)

    if ok then
        return choice
    end

    return nil
end

---@param ctx? phantom-code.VirtualtextSuggestionContext
local function update_preview(ctx)
    ctx = ctx or get_ctx()

    if utils.is_expand_prompt_buffer() then
        return
    end

    local suggestion = get_current_suggestion(ctx)
    local display_lines = suggestion and vim.split(suggestion, '\n', { plain = true }) or {}

    clear_preview(api.nvim_get_current_buf())

    local show_on_completion_menu = require('phantom-code').config.inline.virtualtext.show_on_completion_menu

    if not suggestion or #display_lines == 0 or (not show_on_completion_menu and completion_menu_visible()) then
        ctx.is_floating = nil
        return
    end

    local annot = ''

    if ctx.suggestions and #ctx.suggestions > 1 then
        annot = '(' .. ctx.choice .. '/' .. #ctx.suggestions .. ')'
    end

    local cursor_col = vim.fn.col '.'
    local cursor_line = vim.fn.line '.'
    local row0, col0 = cursor_line - 1, cursor_col - 1

    local cmp_ctx = utils.make_cmp_context()
    local line_after = cmp_ctx.cursor_after_line or ''
    local first_line = display_lines[1] or ''
    local is_floating = #line_after > 0 and not utils.string_contains(first_line, line_after)
    ctx.is_floating = is_floating

    -- Mid-line cursor: inline virt text would overlap real text after the cursor, so we paint
    -- only the first suggestion line at EOL (`virt_lines` for continuation lines are omitted).

    local extmark = {
        id = internal.extmark_id,
        virt_text = { { first_line, 'PhantomCodeVirtualText' } },
        virt_text_pos = 'inline',
    }

    if is_floating then
        local line_before = cmp_ctx.cursor_before_line or ''
        local lb = line_before:gsub('^%s*', '')
        extmark.virt_text = { { lb .. first_line, 'PhantomCodeVirtualText' } }
        extmark.virt_text_pos = 'eol'
        extmark.hl_mode = 'combine'
        if #annot > 0 then
            extmark.virt_text[1][1] = extmark.virt_text[1][1] .. ' ' .. annot
        end
        -- col0 is used as the insertion anchor by action.accept; eol positioning ignores the column.
        api.nvim_buf_set_extmark(0, internal.ns_id, row0, col0, extmark)
    else
        if #display_lines > 1 then
            extmark.virt_lines = {}
            for i = 2, #display_lines do
                extmark.virt_lines[i - 1] = { { display_lines[i], 'PhantomCodeVirtualText' } }
            end

            local last_line = #display_lines - 1
            extmark.virt_lines[last_line][1][1] = extmark.virt_lines[last_line][1][1] .. ' ' .. annot
        elseif #annot > 0 then
            extmark.virt_text[1][1] = extmark.virt_text[1][1] .. ' ' .. annot
        end

        extmark.hl_mode = 'replace'
        api.nvim_buf_set_extmark(0, internal.ns_id, row0, col0, extmark)
    end

    ctx.shown_choices = ctx.shown_choices or {}
    if not ctx.shown_choices[suggestion] then
        ctx.shown_choices[suggestion] = true
    end

    ctx.last_pos = api.nvim_win_get_cursor(0)
    ctx.preview_anchor = { row0, col0 }
end

---@param bufnr? integer defaults to current buffer
---@param opts? { cancel_jobs?: boolean }
local function cleanup(bufnr, opts)
    opts = opts or {}
    bufnr = bufnr or api.nvim_get_current_buf()
    local ctx = get_ctx(bufnr)
    stop_timer()
    reset_ctx(ctx)
    clear_preview(bufnr)
    -- Invalidate pending callbacks started before this cleanup.
    internal.current_completion_timestamp = math.max(uv.now(), internal.current_completion_timestamp + 1)
    if opts.cancel_jobs then
        require('phantom-code.backends.common').terminate_all_jobs()
    end
end

---@param ctx phantom-code.VirtualtextSuggestionContext
---@return boolean Returns true if there are suggestions matching the user’s typed text; otherwise, false.
local function update_suggestion_on_typing(ctx)
    if not (ctx and ctx.suggestions and ctx.choice) then
        return false
    end

    local last_typed_text = get_last_typed_text()
    if not (last_typed_text and #last_typed_text > 0) then
        return false
    end

    local typed = table.concat(last_typed_text, '\n')
    if #typed == 0 or typed ~= ctx.suggestions[ctx.choice]:sub(1, #typed) then
        return false
    end

    for i, suggestion in ipairs(ctx.suggestions) do
        if suggestion:sub(1, #typed) == typed then
            ctx.suggestions[i] = suggestion:sub(#typed + 1, -1)
        else
            ctx.suggestions[i] = ''
        end
    end

    update_preview(ctx)
    stop_timer()
    return true
end

local function trigger(bufnr)
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return
    end

    if utils.is_expand_prompt_buffer(bufnr) then
        return
    end

    utils.notify('phantom-code virtual text started', 'verbose')

    local config = require('phantom-code').config

    local cmp_ctx = utils.make_cmp_context()
    local captured_cursor = api.nvim_win_get_cursor(0)
    -- Use the tail variant: the completion cache only stores the last 512 bytes
    -- anyway, so reading the full prefix from buffer start is wasted allocation.
    local captured_prefix = get_cursor_prefix_tail(bufnr, captured_cursor)
    local context = utils.enrich_llm_context(utils.get_context(cmp_ctx), cmp_ctx)

    local resolved = utils.resolve_provider_config 'inline'
    if resolved.provider == '' then
        return
    end
    local ok, provider = pcall(require, 'phantom-code.backends.' .. resolved.provider)
    if not ok then
        utils.notify(
            'phantom-code: failed to load backend "' .. resolved.provider .. '": ' .. tostring(provider),
            'error',
            vim.log.levels.ERROR
        )
        return
    end
    local timestamp = uv.now()
    internal.current_completion_timestamp = timestamp

    provider.complete(context, function(data)
        if timestamp ~= internal.current_completion_timestamp then
            if data and next(data) then
                -- Notify if outdated (and non-empty) completion items arrive
                utils.notify('Completion items arrived, but too late, aborted', 'debug', 'info')
            end
            return
        end

        data = utils.list_dedup(data or {})

        data = vim.tbl_map(function(item)
            if type(item) ~= 'string' then
                return item
            end
            return utils.prepend_to_complete_word(item, context.lines_before)
        end, data)

        if config.inline.add_single_line_entry then
            data = utils.add_single_line_entry(data)
        end

        -- Single pass: dedup + max_lines truncation + normalize.
        -- Previously three separate tbl_map / list_dedup calls allocated
        -- three intermediate tables; coalescing them cuts GC pressure on the
        -- inline response path (fires on every debounce cycle while typing).
        local max_lines = config.inline and config.inline.max_lines
        local do_normalize = config.inline.normalize_on_accept ~= false
        if max_lines or do_normalize then
            local norm_before, norm_after, norm_opts
            if do_normalize then
                local col_byte = cmp_ctx.cursor.col - 1
                if col_byte < 0 then
                    col_byte = 0
                end
                norm_before = string.sub(cmp_ctx.cursor_line, 1, col_byte)
                norm_after = string.sub(cmp_ctx.cursor_line, col_byte + 1)
                norm_opts = { bufnr = cmp_ctx.bufnr, row0 = cmp_ctx.cursor.line, col0_byte = col_byte }
            end
            local seen = {}
            local coalesced = {}
            for _, item in ipairs(data) do
                if type(item) == 'string' then
                    if max_lines then
                        local lines = vim.split(item, '\n', { plain = true })
                        if #lines > max_lines then
                            item = table.concat(vim.list_slice(lines, 1, max_lines), '\n')
                        end
                    end
                    if do_normalize then
                        item = utils.normalize_inline_accept_suggestion(norm_before, norm_after, item, norm_opts)
                    end
                end
                if not seen[item] then
                    seen[item] = true
                    coalesced[#coalesced + 1] = item
                end
            end
            data = coalesced
        end

        data = filter_inactive_blank_line_suggestions(data, cmp_ctx.cursor_before_line)

        local ctx = get_ctx()

        local nonempty = false
        for _, item in ipairs(data) do
            if type(item) == 'string' and item ~= '' then
                nonempty = true
                break
            end
        end
        if not nonempty then
            ctx.suggestions = nil
            ctx.choice = nil
            ctx.shown_choices = nil
            update_preview(ctx)
            return
        end

        if next(data) then
            ctx.suggestions = data
            if not ctx.choice then
                ctx.choice = 1
            end
            ctx.shown_choices = {}
            push_completion_cache(ctx, captured_prefix, data)
        end

        update_preview(ctx)
    end, { provider_options = resolved.options })
end

local function advance(count, ctx)
    if ctx ~= get_ctx() then
        return
    end

    ctx.choice = (ctx.choice + count) % #ctx.suggestions
    if ctx.choice < 1 then
        ctx.choice = #ctx.suggestions
    end

    update_preview(ctx)
end

local function schedule()
    if internal.is_on_throttle then
        return
    end

    stop_timer()

    local config = require('phantom-code').config
    local bufnr = api.nvim_get_current_buf()
    if utils.is_expand_prompt_buffer(bufnr) then
        return
    end

    internal.timer = vim.defer_fn(function()
        if utils.is_expand_prompt_buffer(api.nvim_get_current_buf()) then
            return
        end
        local show_on_completion_menu = require('phantom-code').config.inline.virtualtext.show_on_completion_menu

        local cmp_ctx_gate = utils.make_cmp_context()
        if
            internal.is_on_throttle
            or (not show_on_completion_menu and completion_menu_visible())
            or (not utils.run_hooks_until_failure(config.inline.enable_predicates))
            or utils.should_skip_inline_request(cmp_ctx_gate)
        then
            return
        end

        internal.is_on_throttle = true
        vim.defer_fn(function()
            internal.is_on_throttle = false
        end, config.inline.throttle)

        trigger(bufnr)
    end, config.inline.debounce)
end

--- Rate-limit CursorMovedI-driven scheduling (typing); does not wrap InsertEnter.
local function throttled_schedule()
    local config = require('phantom-code').config
    local ms = config.inline.cursor_moved_throttle_ms or 0
    if ms <= 0 then
        schedule()
        return
    end
    local now = uv.now()
    if now - internal.last_cursor_moved_schedule_ms < ms then
        return
    end
    internal.last_cursor_moved_schedule_ms = now
    schedule()
end

local action = {}

action.next = function()
    if utils.is_expand_prompt_buffer() then
        return
    end
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf())
        return
    end

    advance(1, ctx)
end

action.prev = function()
    if utils.is_expand_prompt_buffer() then
        return
    end
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf())
        return
    end

    advance(-1, ctx)
end

---@param n_lines? integer Number of lines to accept from the suggestion. If nil, accepts all lines.
---@param accept_opts? { remainder?: string } When set after a partial accept (e.g. word), text to keep as the active ghost without a new HTTP request.
---Accepts the current suggestion by inserting it at the cursor position.
---If n_lines is provided, only the first n_lines of the suggestion are inserted.
---After insertion, moves the cursor to the end of the inserted text.
function action.accept(n_lines, accept_opts)
    accept_opts = accept_opts or {}
    if utils.is_expand_prompt_buffer() then
        return
    end
    local ctx = get_ctx()

    local suggestion = get_current_suggestion(ctx)
    if not suggestion then
        return
    end

    local suggestions = vim.split(suggestion, '\n')
    local remaining_suggestions = {}
    local remainder = accept_opts.remainder
    local has_remainder = type(remainder) == 'string' and remainder ~= ''

    if n_lines then
        -- NOTE: If the first line is an empty string (""), it indicates that
        -- the original suggestion began with a newline character. This
        -- typically occurs during partial completion: when the user accepts
        -- the first line, the remaining suggestion may start with '\n'. In
        -- this scenario, we increment n_lines by 1 because the user intends to
        -- accept the next visible line of text, which corresponds to the
        -- subsequent element in the suggestions list.
        if suggestions[1] == '' then
            n_lines = n_lines + 1
        end
        n_lines = math.min(n_lines, #suggestions)
        remaining_suggestions = vim.list_slice(suggestions, n_lines + 1, #suggestions)
        suggestions = vim.list_slice(suggestions, 1, n_lines)
    end

    if #remaining_suggestions <= 0 and not has_remainder then
        reset_ctx(ctx)
    end

    local bufnr = api.nvim_get_current_buf()
    local ext = api.nvim_buf_get_extmark_by_id(bufnr, internal.ns_id, internal.extmark_id, {})
    local line, col
    if ext[1] ~= nil and ext[2] ~= nil then
        line, col = ext[1], ext[2]
    elseif ctx.preview_anchor then
        line, col = ctx.preview_anchor[1], ctx.preview_anchor[2]
    else
        local cursor = api.nvim_win_get_cursor(0)
        line, col = cursor[1] - 1, cursor[2]
    end

    clear_preview(bufnr)

    local row_line = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ''
    local before_part = vim.fn.strcharpart(row_line, 0, col)
    local after_part = vim.fn.strcharpart(row_line, col, vim.fn.strchars(row_line) - col)

    vim.schedule(function()
        if not api.nvim_buf_is_valid(bufnr) then
            return
        end
        if #suggestions > 0 and require('phantom-code').config.inline.normalize_on_accept ~= false then
            suggestions[1] = utils.normalize_inline_accept_suggestion(before_part, after_part, suggestions[1], {
                bufnr = bufnr,
                row0 = line,
                col0_byte = col,
            })
        end
        api.nvim_buf_set_text(bufnr, line, col, line, col, suggestions)
        local new_col = #suggestions[#suggestions]
        if #suggestions == 1 then
            new_col = new_col + col
        end
        if api.nvim_win_get_buf(0) == bufnr then
            api.nvim_win_set_cursor(0, { line + #suggestions, new_col })
        end
        if has_remainder and ctx.suggestions and ctx.choice then
            ctx.suggestions[ctx.choice] = remainder
            update_preview(ctx)
        end
    end)
end

function action.accept_n_lines()
    if utils.is_expand_prompt_buffer() then
        return
    end
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local n = vim.fn.input 'accept n lines: '

    -- FIXME: vim.fn.input may change cursor position, we need to restore the
    -- cursor position after the user input.

    vim.api.nvim_win_set_cursor(0, cursor_pos)

    ---@diagnostic disable-next-line:cast-local-type
    n = tonumber(n)
    if not n then
        return
    end
    if n > 0 then
        action.accept(n)
    else
        vim.notify('Invalid number of lines', vim.log.levels.ERROR)
    end
end

function action.accept_line()
    action.accept(1)
end

function action.accept_word()
    if utils.is_expand_prompt_buffer() then
        return
    end
    local ctx = get_ctx()
    local suggestion = get_current_suggestion(ctx)
    if not suggestion then
        return
    end
    local word = utils.to_next_word(suggestion)
    if word == '' then
        utils.notify('phantom-code: accept_word found no word token in suggestion', 'debug')
        return
    end
    local tail = suggestion:sub(#word + 1)
    local n = #vim.split(word, '\n', { plain = true })
    ctx.suggestions[ctx.choice] = word
    action.accept(n, { remainder = tail })
end

function action.dismiss()
    cleanup(nil, { cancel_jobs = true })
end

function action.is_visible()
    return not not api.nvim_buf_get_extmark_by_id(0, internal.ns_id, internal.extmark_id, { details = false })[1]
end

function action.disable_auto_trigger()
    vim.b.phantom_code_virtual_text_auto_trigger = false
    vim.notify('PhantomCode Virtual Text auto trigger disabled', vim.log.levels.INFO)
end

function action.enable_auto_trigger()
    vim.b.phantom_code_virtual_text_auto_trigger = true
    vim.notify('PhantomCode Virtual Text auto trigger enabled', vim.log.levels.INFO)
end

function action.toggle_auto_trigger()
    vim.b.phantom_code_virtual_text_auto_trigger = not should_auto_trigger()
    vim.notify(
        'PhantomCode Virtual Text auto trigger ' .. (should_auto_trigger() and 'enabled' or 'disabled'),
        vim.log.levels.INFO
    )
end

M.action = action

local autocmd = {}

function autocmd.on_insert_leave()
    cleanup(nil, { cancel_jobs = true })
end

function autocmd.on_buf_leave()
    if not vim.fn.mode():match '^[iR]' then
        return
    end
    local leaving_buf = api.nvim_get_current_buf()
    vim.schedule(function()
        if utils.is_expand_prompt_buffer(api.nvim_get_current_buf()) then
            return
        end
        cleanup(leaving_buf)
    end)
end

function autocmd.on_insert_enter()
    if utils.is_expand_prompt_buffer() then
        return
    end
    if should_auto_trigger() then
        local b = api.nvim_get_current_buf()
        get_ctx(b).last_changedtick = api.nvim_buf_get_changedtick(b)
        schedule()
    end
end

function autocmd.on_buf_enter()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_enter()
    end
end

function autocmd.on_cursor_moved_i()
    if utils.is_expand_prompt_buffer() then
        cleanup(nil, { cancel_jobs = true })
        return
    end
    local ctx = get_ctx()
    local bufnr = api.nvim_get_current_buf()

    if update_suggestion_on_typing(ctx) then
        -- Record tick so the next cursor-move without a new edit exits early.
        ctx.last_changedtick = api.nvim_buf_get_changedtick(bufnr)
        return
    end

    if should_auto_trigger() then
        local tick = api.nvim_buf_get_changedtick(bufnr)
        if ctx.last_changedtick ~= nil and tick == ctx.last_changedtick then
            return
        end
        ctx.last_changedtick = tick
        local cur = api.nvim_win_get_cursor(0)
        local current_prefix = get_cursor_prefix_tail(bufnr, cur)
        if try_completion_cache(ctx, current_prefix) then
            return
        end
        throttled_schedule()
    end
end

function autocmd.on_cursor_hold_i()
    update_preview()
end

-- TextChangedP only runs with the completion popup visible; CursorMovedI already
-- runs on normal insert typing — avoid doubling work every keystroke.
function autocmd.on_text_changed_p()
    if completion_menu_visible() then
        autocmd.on_cursor_moved_i()
    end
end

---@param info { buf: integer }
function autocmd.on_buf_unload(info)
    internal.context[info.buf] = nil
end

local function create_autocmds()
    api.nvim_create_autocmd('InsertLeave', {
        group = internal.augroup,
        callback = autocmd.on_insert_leave,
        desc = '[phantom-code.virtualtext] insert leave',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = internal.augroup,
        callback = autocmd.on_buf_leave,
        desc = '[phantom-code.virtualtext] buf leave',
    })

    api.nvim_create_autocmd('InsertEnter', {
        group = internal.augroup,
        callback = autocmd.on_insert_enter,
        desc = '[phantom-code.virtualtext] insert enter',
    })

    api.nvim_create_autocmd('BufEnter', {
        group = internal.augroup,
        callback = autocmd.on_buf_enter,
        desc = '[phantom-code.virtualtext] buf enter',
    })

    api.nvim_create_autocmd('CursorMovedI', {
        group = internal.augroup,
        callback = autocmd.on_cursor_moved_i,
        desc = '[phantom-code.virtualtext] cursor moved insert',
    })

    api.nvim_create_autocmd('TextChangedP', {
        group = internal.augroup,
        callback = autocmd.on_text_changed_p,
        desc = '[phantom-code.virtualtext] text changed p',
    })

    api.nvim_create_autocmd('BufUnload', {
        group = internal.augroup,
        callback = autocmd.on_buf_unload,
        desc = '[phantom-code.virtualtext] buf unload',
    })
end

local function set_keymaps(keymap)
    if keymap.accept then
        vim.keymap.set('i', keymap.accept, action.accept, {
            desc = '[phantom-code.virtualtext] accept suggestion',
            silent = true,
        })
    end

    if keymap.accept_line then
        vim.keymap.set('i', keymap.accept_line, action.accept_line, {
            desc = '[phantom-code.virtualtext] accept suggestion (line)',
            silent = true,
        })
    end

    if keymap.accept_n_lines then
        vim.keymap.set('i', keymap.accept_n_lines, action.accept_n_lines, {
            desc = '[phantom-code.virtualtext] accept suggestion (n lines)',
            silent = true,
        })
    end

    if keymap.accept_word then
        vim.keymap.set('i', keymap.accept_word, action.accept_word, {
            desc = '[phantom-code.virtualtext] accept suggestion (word)',
            silent = true,
        })
    end

    if keymap.next then
        vim.keymap.set('i', keymap.next, action.next, {
            desc = '[phantom-code.virtualtext] next suggestion',
            silent = true,
        })
    end

    if keymap.prev then
        vim.keymap.set('i', keymap.prev, action.prev, {
            desc = '[phantom-code.virtualtext] prev suggestion',
            silent = true,
        })
    end

    if keymap.dismiss then
        vim.keymap.set('i', keymap.dismiss, action.dismiss, {
            desc = '[phantom-code.virtualtext] dismiss suggestion',
            silent = true,
        })
    end
end

function M.setup()
    local config = require('phantom-code').config
    api.nvim_clear_autocmds { group = M.augroup }

    if #config.inline.virtualtext.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.inline.virtualtext.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(config.inline.virtualtext.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.phantom_code_virtual_text_auto_trigger = true
                end
            end,
            group = M.augroup,
            desc = 'phantom-code virtual text filetype auto trigger',
        })
    end

    create_autocmds()
    set_keymaps(config.inline.virtualtext.keymap)
end

return M