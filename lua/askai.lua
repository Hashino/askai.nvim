local config = require("askai.config")
local ai = require("askai.ai")

local AskAI = {
  win_id = nil,
  spinner_win = nil,
  spinner_timer = nil,
  spinner_idx = 1,
}

--- Get the visual selection text from the '< and '> marks.
--- Returns nil if no valid selection exists.
---@param buf integer buffer handle
---@return string|nil
local function get_visual_selection(buf)
  local mode = vim.fn.visualmode()
  if not mode then return nil end

  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  if start_pos[1] == 0 and end_pos[1] == 0 then
    return nil
  end

  if mode == "V" then
    -- linewise: extend start to column 0
    start_pos[2] = 0
  end

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

--- Compute a sensible width/height that fits the content while staying within bounds.
local function compute_dimensions(lines)
  local max_line_width = 0
  for _, l in ipairs(lines) do
    max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(l))
  end

  local width = math.min(math.max(max_line_width + 4, 40), vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 6)

  return width, height
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

  -- close existing window
  if AskAI.win_id and vim.api.nvim_win_is_valid(AskAI.win_id) then
    pcall(vim.api.nvim_win_close, AskAI.win_id, true)
    AskAI.win_id = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

  local summary_lines = vim.split(response.summary, "\n", { plain = true })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, summary_lines)

  -- markdown syntax highlighting (if treesitter is available, use filetype instead)
  vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

  -- compute dynamic dimensions from content
  local win_config = vim.deepcopy(config.options.win_config)
  local dyn_width, dyn_height = compute_dimensions(summary_lines)
  win_config.width = dyn_width
  win_config.height = dyn_height
  -- reposition so it's still anchored at the bottom-right area
  win_config.col = vim.o.columns - dyn_width
  win_config.row = vim.o.lines - 3 - vim.o.cmdheight - dyn_height

  -- dismiss keymap
  vim.keymap.set("n", config.options.keys.dismiss, function()
    if AskAI.win_id and vim.api.nvim_win_is_valid(AskAI.win_id) then
      pcall(vim.api.nvim_win_close, AskAI.win_id, true)
      AskAI.win_id = nil
    end
  end, { buffer = buf })

  -- Only pass keys valid for nvim_open_win; apply window-local options after
  local open_win_valid = {
    relative = true, win = true, bufpos = true, width = true, height = true,
    row = true, col = true, zindex = true, style = true, border = true,
    title = true, title_pos = true, footer = true, footer_pos = true,
    noautocmd = true, fixed = true, anchor = true, focusable = true,
  }
  local post_opts = {}
  for k, v in pairs(win_config) do
    if not open_win_valid[k] then
      post_opts[k] = v
      win_config[k] = nil
    end
  end

  AskAI.win_id = vim.api.nvim_open_win(buf, true, win_config)

  -- Apply window-local options that aren't valid for nvim_open_win
  for k, v in pairs(post_opts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = AskAI.win_id })
  end

  -- clean up when the window is closed manually (e.g. :q)
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function()
      AskAI.win_id = nil
    end,
  })

  -- if there's a valid edit suggestion, add confirm keymap and winbar hint
  if response.edit
      and type(response.edit.start) == "number"
      and type(response.edit.final) == "number"
      and type(response.edit.content) == "table" then
    vim.keymap.set("n", config.options.keys.confirm, function()
      pcall(vim.api.nvim_win_close, AskAI.win_id, true)
      AskAI.win_id = nil
      if not (vim.api.nvim_buf_is_valid(toedit) and vim.api.nvim_buf_is_loaded(toedit)) then
        return
      end
      vim.api.nvim_buf_set_lines(toedit, response.edit.start, response.edit.final, false,
        response.edit.content)
    end, { buffer = buf })

    vim.api.nvim_set_option_value("winbar",
      string.format(" %s to accept | %s to dismiss",
        config.options.keys.confirm, config.options.keys.dismiss),
      { win = AskAI.win_id })
  else
    vim.api.nvim_set_option_value("winbar",
      string.format(" %s to dismiss", config.options.keys.dismiss),
      { win = AskAI.win_id })
  end
end

--- Braille spinner animation (bottom-right corner, fidget.nvim style).
local function show_spinner()
  if AskAI.spinner_win and vim.api.nvim_win_is_valid(AskAI.spinner_win) then
    return -- already showing
  end

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
  AskAI.spinner_timer = vim.uv.new_timer()
  AskAI.spinner_timer:start(config.options.spinner_interval_ms,
    config.options.spinner_interval_ms, vim.schedule_wrap(function()
      if not AskAI.spinner_win or not vim.api.nvim_win_is_valid(AskAI.spinner_win) then
        return
      end
      AskAI.spinner_idx = (AskAI.spinner_idx % #config.options.spinner_characters) + 1
      local spinner_buf = vim.api.nvim_win_get_buf(AskAI.spinner_win)
      vim.api.nvim_buf_set_lines(spinner_buf, 0, -1, false,
        { config.options.spinner_characters[AskAI.spinner_idx] })
    end))
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

--- Create all user-configured highlight groups.
local function setup_highlight()
  for group, spec in pairs(config.options.highlights) do
    if type(spec) == "string" then
      pcall(vim.api.nvim_set_hl, 0, group, { link = spec })
    elseif type(spec) == "table" then
      pcall(vim.api.nvim_set_hl, 0, group, spec)
    end
  end
end

--- Main entry point: ask the AI a question with context.
--- If called without a question, prompts via vim.fn.input().
---@param question? string the question to ask the AI
function AskAI.ask(question)
  if question == nil or question == "" then
    question = vim.fn.input("Ask AI: ")
    if question == "" then
      return
    end
  end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  -- get visual selection if any
  local selected_text = get_visual_selection(buf)

  -- get full document text (truncated to avoid token limits)
  local full_doc = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local full_text = table.concat(full_doc, "\n")
  local max_ctx = config.options.max_context_size
  if #full_text > max_ctx then
    full_text = string.sub(full_text, 1, max_ctx)
      .. "\n\n-- [[ ... truncated to " .. max_ctx .. " characters ... ]]"
  end
  local filetype = vim.bo[buf].filetype

  -- build the prompt
  local prompt_parts = {}
  table.insert(prompt_parts, "I have a question about a specific portion of this code.\n")

  -- Full document first (as context)
  table.insert(prompt_parts, "Full document (for context only, filetype: " .. filetype .. "):\n```" .. filetype .. "\n")
  table.insert(prompt_parts, full_text)
  table.insert(prompt_parts, "\n```\n")

  if selected_text then
    table.insert(prompt_parts, "\nSelected portion (the question is about THIS code):\n```" .. filetype .. "\n")
    table.insert(prompt_parts, selected_text)
    table.insert(prompt_parts, "\n```\n")
  end

  table.insert(prompt_parts, "Question: " .. question .. "\n")

  table.insert(prompt_parts, "\nAnswer the question specifically about the selected portion. Use the full document only as context.\n")

  table.insert(prompt_parts, [[
Respond in JSON format with no extra commentary:

{
  "summary": "Answer in markdown. Include code snippets in ``` fences.",
  "edit": {
    "start": <0-indexed start line of the edit>,
    "final": <0-indexed end line (exclusive) of the edit>,
    "content": ["replacement line 1", "replacement line 2", "..."]
  }
}

If suggesting a replacement edit, the "content" replaces lines from start to final in the document.
If no edit is suggested, omit the "edit" field entirely.]])

  local prompt = table.concat(prompt_parts, "\n")

  -- show spinner
  show_spinner()

  -- make the AI request
  ai.ask(prompt, function(response)
    hide_spinner()
    if response and response.summary then
      AskAI.show(buf, response)
    else
      vim.notify("[askai.nvim] No response from AI", vim.log.levels.WARN)
    end
  end)
end

--- Setup askai.nvim
---@param opts? askai.Config
function AskAI.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if config.options.provider.api_url == ""
      or config.options.provider.model == ""
      or config.options.provider.api_key == "" then
    vim.notify("[askai.nvim] provider.api_url, provider.model and provider.api_key must be set",
      vim.log.levels.ERROR)
    return
  end

  setup_highlight()
end

return AskAI
