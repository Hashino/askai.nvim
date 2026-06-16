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

  -- Ensure win_config always has required fields (user can override but not remove)
  local default_win_config = {
    relative = "editor",
    width = 75,
    height = 25,
    col = vim.o.columns - 75,
    row = vim.o.lines - 3 - vim.o.cmdheight - 25,
    style = "minimal",
    border = "rounded",
    noautocmd = true,
  }
  config.options.win_config = vim.tbl_deep_extend("force", default_win_config, config.options.win_config or {})

  -- Ensure fenced‑language highlighting works for markdown code blocks
  if vim.g.markdown_fenced_languages == nil then
    vim.g.markdown_fenced_languages = { 'lua', 'python', 'bash=sh', 'js=javascript', 'json', 'yaml', 'html', 'css' }
  end

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
    vim.notify("[askai.nvim] Provider validation failed: " .. validation.error, vim.log.levels.ERROR)
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

  vim.notify("[askai.nvim] Provider validated successfully", vim.log.levels.INFO)
  AskAI._initialized = true
end

--- Extract visual selection text from the '< and '> marks.
--- Returns nil if no valid selection exists.
---@param buf integer buffer handle
---@return string|nil
local function get_visual_selection(buf)
  local mode = vim.fn.visualmode()
  if not mode then return nil end

  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  if start_pos[1] == 0 and end_pos[1] == 0 then return nil end

  if mode == "V" then start_pos[2] = 0 end

  -- normalize so start <= end
  if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
    start_pos, end_pos = end_pos, start_pos
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_pos[1] - 1, end_pos[1], false)
  if #lines == 0 then return nil end

  -- characterwise / blockwise: slice first and last line
  if mode == "v" or mode == "\22" then
    lines[1] = string.sub(lines[1], start_pos[2] + 1)
    if #lines == 1 then
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] - start_pos[2])
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
  -- Convert escaped \n sequences to actual newlines
  response.summary = response.summary:gsub('\\\\n', '\n')
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
  vim.api.nvim_set_option_value("syntax",   "markdown", { buf = buf })
  -- Start Tree‑sitter highlighting for markdown (if available)
  if vim.treesitter and vim.treesitter.start then
    pcall(vim.treesitter.start, buf, 'markdown')
  end

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
  local selected_text = get_visual_selection(buf)

  -- Get full document text (truncated to avoid token limits)
  local full_doc = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local full_text = table.concat(full_doc, "\n")
  local max_ctx = config.options.max_context_size
  if #full_text > max_ctx then
    full_text = string.sub(full_text, 1, max_ctx)
        .. "\n\n-- [[ ... truncated to " .. max_ctx .. " characters ... ]]"
  end
  local filetype = vim.bo[buf].filetype

  -- Build the prompt
  local prompt_parts = {}
  table.insert(prompt_parts, "Answer the user's question about the selected text in the context of the full document.\n")
  table.insert(prompt_parts, "\n--- Document (filetype: " .. filetype .. ") ---\n```" .. filetype .. "\n")
  table.insert(prompt_parts, full_text)
  table.insert(prompt_parts, "\n```\n")

  if selected_text then
    table.insert(prompt_parts, "\n--- Selected text (focus of the question) ---\n```" .. filetype .. "\n")
    table.insert(prompt_parts, selected_text)
    table.insert(prompt_parts, "\n```\n")
  end

  table.insert(prompt_parts, "\n--- Question ---\n")
  table.insert(prompt_parts, question)
  table.insert(prompt_parts, "\n")

  table.insert(prompt_parts, [[
Respond in JSON format with no extra commentary:
{
  "summary": "If the user asks to DO something (refactor, fix, change, add, etc.), describe WHAT WILL BE CHANGED in future tense, and include a fenced code block with the language annotated **inside the summary** showing the resulting code AFTER the edit. If the question is informational, explain the answer. Use markdown with ```<language> fences for code, where <language> matches the filetype of the edited code. You **MUST** include a fenced code block (annotated with the filetype) that shows the code **after** the edit. Insert newline characters (\\n) in the summary to separate sections (e.g., description and the fenced code block) and improve its readability."
  "edit": {
    "start": <0-indexed start line of the edit>,
    "final": <0-indexed end line (exclusive) of the edit>,
    "content": ["replacement line 1", "replacement line 2", "..."]
  }
}

If the user asks to do something (refactor, fix, change, add, etc.), include the "edit" field with the exact change.
If the question is just informational, omit the "edit" field and return only { "summary": "..." }.
Focus your answer on the selected text (or the whole document if no selection).]])

  local prompt = table.concat(prompt_parts, "\n")

  show_spinner()
  ai.ask(prompt, function(response)
    hide_spinner()
    if response and response.summary then
      AskAI.show(buf, response)
    else
      vim.notify("[askai.nvim] No response from AI", vim.log.levels.WARN)
    end
  end)
end

return AskAI
