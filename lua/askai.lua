local config = require("askai.config")
local ai = require("askai.ai")

local AskAI = {
  win_id = nil,
  spinner_win = nil,
  spinner_timer = nil,
  spinner_idx = 1,

  ---@type integer?
  augroup = nil,

  ---@type boolean
  _initialized = false,
}

--- Setup askai.nvim
---@param opts? askai.Config
function AskAI.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if config.options.provider.api_url == ""
      or config.options.provider.model == ""
      or config.options.provider.api_key == "" then
    vim.notify("[askai.nvim] provider.api_url, provider.model and provider.api_key must be set",
      vim.log.levels.ERROR)
    AskAI._initialized = false
    return
  end

  -- Validate provider with a test request
  local validation = ai.validate_provider()
  if not validation.success then
    vim.notify("[askai.nvim] provider validation failed: " .. validation.error, vim.log.levels.ERROR)
    AskAI._initialized = false
    return
  end

  AskAI.augroup = vim.api.nvim_create_augroup("AskAI", { clear = true })

  for group, spec in pairs(config.options.highlights) do
    if type(spec) == "string" then
      pcall(vim.api.nvim_set_hl, 0, group, { link = spec })
    elseif type(spec) == "table" then
      pcall(vim.api.nvim_set_hl, 0, group, spec)
    end
  end

  vim.notify("[askai.nvim] provider validated successfully", vim.log.levels.INFO)
  AskAI._initialized = true
end

--- Extract visual selection text from the '< and '> marks.
--- Returns nil if no valid selection exists.
---@param buf integer buffer handle
---@return string|nil
local function get_visual_selection(buf)
  local mode = vim.fn.visualmode()

  if not mode or mode == "" then
    local cur = vim.api.nvim_get_mode().mode
    if cur == "v" or cur == "V" then
      mode = cur
    elseif cur == "\22" then
      mode = "\22"
    else
      return nil
    end
  end

  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return nil end

  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  if start_pos[1] == 0 and end_pos[1] == 0 then
    local v_start = vim.fn.getpos("v")
    local v_end = vim.fn.getpos(".")
    start_pos = { v_start[2], v_start[3] - 1 }
    end_pos = { v_end[2], v_end[3] - 1 }
  end

  if mode == "V" then
    start_pos[2] = 0
  end

  if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
    start_pos, end_pos = end_pos, start_pos
  end

  local start_line = start_pos[1] - 1

  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_pos[1], false)
  if #lines == 0 then return nil end

  if mode == "v" or mode == "\22" then
    lines[1] = string.sub(lines[1], start_pos[2] + 1)
    if #lines == 1 then
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] - start_pos[2] + 1)
    else
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
    end
  end

  return table.concat(lines, "\n")
end

--- Show a floating window with the AI response.
---@param toedit integer buffer to apply edits to
---@param response { summary: string, edit?: { start: integer, final: integer, content: string[] } }
function AskAI.show(toedit, response)
  if not response or not response.summary then return end

  -- Trim whitespace; if truly empty, don't show an empty window
  local trimmed = vim.trim(response.summary)
  if trimmed == "" then
    vim.notify("[askai.nvim] AI returned an empty response", vim.log.levels.WARN)
    return
  end
  response.summary = trimmed

  -- Close existing window
  if AskAI.win_id and vim.api.nvim_win_is_valid(AskAI.win_id) then
    pcall(vim.api.nvim_win_close, AskAI.win_id, true)
    AskAI.win_id = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

  local summary_lines = vim.split(response.summary, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, summary_lines)

  -- Markdown syntax highlighting
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
  -- Trigger FileType autocommands (e.g., to load markdown fenced‑language syntax or Tree‑sitter)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('doautocmd FileType markdown')
    -- Start Tree‑sitter highlighting for markdown if available
    if vim.treesitter and vim.treesitter.start then
      pcall(vim.treesitter.start, buf, 'markdown')
    end
  end)

  -- Compute dynamic dimensions from content
  local win_config = config.options.win_config

  -- Dismiss keymap
  vim.keymap.set("n", config.options.keys.dismiss, function()
    if AskAI.win_id and vim.api.nvim_win_is_valid(AskAI.win_id) then
      pcall(vim.api.nvim_win_close, AskAI.win_id, true)
      AskAI.win_id = nil
    end
  end, { buffer = buf })

  ---@diagnostic disable-next-line: param-type-mismatch
  AskAI.win_id = vim.api.nvim_open_win(buf, true, win_config)

  -- Clean up when the window is closed manually (e.g. :q)
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function() AskAI.win_id = nil end,
  })

  -- If there's a valid edit suggestion, add confirm keymap and winbar hint
  local edit = response.edit
  if edit and type(edit.start) == "number" and type(edit.final) == "number" and type(edit.content) == "table" then
    vim.keymap.set("n", config.options.keys.confirm, function()
      pcall(vim.api.nvim_win_close, AskAI.win_id, true)
      AskAI.win_id = nil
      if vim.api.nvim_buf_is_valid(toedit) and vim.api.nvim_buf_is_loaded(toedit) then
        vim.api.nvim_buf_set_lines(toedit, edit.start, edit.final, false, edit.content)
      end
    end, { buffer = buf })

    vim.api.nvim_set_option_value("winbar",
      string.format(" [AskAI] %s to accept | %s to dismiss",
        config.options.keys.confirm, config.options.keys.dismiss),
      { win = AskAI.win_id })
  else
    vim.api.nvim_set_option_value("winbar",
      string.format(" [AskAI] %s to dismiss", config.options.keys.dismiss),
      { win = AskAI.win_id })
  end
end

--- Braille spinner animation (bottom-right corner, fidget.nvim style).
local function show_spinner()
  if AskAI.spinner_win and vim.api.nvim_win_is_valid(AskAI.spinner_win) then return end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { config.options.spinner_characters[1] })

  AskAI.spinner_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = 1,
    height = 1,
    row = vim.o.lines - 3 - vim.o.cmdheight,
    col = vim.o.columns - 2,
    style = "minimal",
    noautocmd = true,
  })

  vim.api.nvim_set_option_value("winhl", "Normal:AskaiSpinner", { win = AskAI.spinner_win })

  AskAI.spinner_idx = 1
  AskAI.spinner_timer = vim.loop.new_timer()
  if AskAI.spinner_timer then
    AskAI.spinner_timer:start(config.options.spinner_interval_ms, config.options.spinner_interval_ms,
      vim.schedule_wrap(function()
        if not AskAI.spinner_win or not vim.api.nvim_win_is_valid(AskAI.spinner_win) then return end
        AskAI.spinner_idx = (AskAI.spinner_idx % #config.options.spinner_characters) + 1
        local spinner_buf = vim.api.nvim_win_get_buf(AskAI.spinner_win)
        vim.api.nvim_buf_set_lines(spinner_buf, 0, -1, false,
          { config.options.spinner_characters[AskAI.spinner_idx] })
      end))
  end
end

local function hide_spinner()
  if AskAI.spinner_timer then
    AskAI.spinner_timer:stop()
    AskAI.spinner_timer:close()
    AskAI.spinner_timer = nil
  end
  if AskAI.spinner_win and vim.api.nvim_win_is_valid(AskAI.spinner_win) then
    pcall(vim.api.nvim_win_close, AskAI.spinner_win, true)
    AskAI.spinner_win = nil
  end
end

--- Main entry point: ask the AI a question with context.
--- If called without a question, prompts via vim.fn.input().
---@param question? string the question to ask the AI
function AskAI.ask(question)
  if not AskAI._initialized then
    vim.notify("[askai.nvim] Plugin not initialized. Call askai.setup() first.", vim.log.levels.ERROR)
    return
  end

  if question == nil or question == "" then
    question = vim.fn.input("Ask AI: ")
    if question == "" then return end
  end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  -- Get visual selection if any
  local selected_text, sel_start_line = get_visual_selection(buf)
  selected_text = selected_text or ""
  sel_start_line = sel_start_line or 0

  -- Get full document text (truncated to avoid token limits)
  local full_file = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local filetype = vim.bo[buf].filetype

  -- Step 1: classify request — is the user asking to change code or to explain it?
  local classify_prompt = [[
Question: ]] .. question .. [[

Classify as "action" if the user wants any code edit (add, change, fix, refactor,
modify, update, remove, rewrite, convert, optimize, simplify, etc.).
Classify as "informational" only if the user just wants an explanation or question
answered without changing the code.

Examples:
- "explain this"              → informational
- "what does this do"         → informational
- "add logging"               → action
- "fix the bug"               → action
- "add emojis to this line"   → action
- "refactor this function"    → action

Return only: {"type": "informational"} or {"type": "action"}
]]

  show_spinner()

  ai.ask(classify_prompt, function(classify_resp)
    if not classify_resp or not classify_resp.type or not (classify_resp.type == "action" or classify_resp.type == "informational") then
      vim.notify("[askai.nvim] could not determine request type", vim.log.levels.WARN)
      return
    end

    local is_action = classify_resp.type == "action"

    local main_prompt = ""

    if is_action then
      main_prompt = [[
{
  "question": "]] .. question .. [["
  "selected_text": "]] .. selected_text .. [["
  "selection_start_line": ]] .. sel_start_line .. [[
  "full_file": "]] .. full_file .. [["
  "filetype": "]] .. filetype .. [["
}

The "edit" replaces lines in the full file. `start` is fixed to
`selection_start_line` (the selection's first line). Only provide
`content` (the replacement lines) and optionally `final` (0-indexed
exclusive end line; defaults to `start + #content`).

Return:
{
  "summary": "brief description + annotated code block showing the result",
  "edit": {
    "content": ["line 1", "line 2", ...]
  }
}

Example for a single-line selection at line 2 asking to add emojis:
{
  "summary": "Will add the 👋 emoji.\n```lua\n  print('👋 hello 👋')```",
  "edit": {
    "content": [" print('👋 hello 👋')"]
  }
}
]]
    else
      main_prompt = [[
{
  "question": "]] .. question .. [["
  "selected_text": "]] .. selected_text .. [["
  "full_file": "]] .. full_file .. [["
  "filetype": "]] .. filetype .. [["
}
Return a JSON object like this:
{
  "summary": answer in markdown to the `question` about the `selected_text` in context to the `full_file`. any fenced code blocks must be annotated with the `filetype`
}
]]
    end

    ai.ask(main_prompt, function(final_resp)
      hide_spinner()
      if final_resp and final_resp.summary then
        -- If the AI omitted the edit field, try to extract a code block from the summary
        if is_action and (not final_resp.edit or type(final_resp.edit) ~= "table" or not final_resp.edit.content) then
          local code_block = final_resp.summary:match("```[^\n]*\n(.-)\n```")
          if code_block then
            final_resp.edit = { content = vim.split(code_block, "\n", { plain = true }) }
          else
            vim.notify("[askai.nvim] AI response missing edit field and no code block found in summary",
              vim.log.levels.ERROR)
            return
          end
        end
        if final_resp.edit and selected_text ~= "" then
          final_resp.edit.start = sel_start_line
          if not final_resp.edit.final then
            final_resp.edit.final = sel_start_line + #final_resp.edit.content
          end
        end
        AskAI.show(buf, final_resp)
      else
        vim.notify("[askai.nvim] No response from AI", vim.log.levels.WARN)
      end
    end)
  end)
end

return AskAI
