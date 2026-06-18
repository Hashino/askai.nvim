local config = require("askai.config")

---@class askai.Utils [Hashino/askai.nvim] utilities

local Utils = {}

-- Spinner state (internal)
local spinner_win = nil ---@type integer?
local spinner_timer = nil
local spinner_idx = 1 ---@type integer

--- Extract visual selection text and its 0-indexed start line.
--- Uses marks `<` and `>` which persist after exiting visual mode.
---@param buf integer buffer handle
---@return string|nil, integer|nil
function Utils.get_visual_selection(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return nil, nil
  end

  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  -- No visual selection marks set
  if start_pos[1] == 0 and end_pos[1] == 0 then
    return nil, nil
  end

  -- Determine visual mode type from visualmode()
  local visual_mode = vim.fn.visualmode()

  -- Ensure start <= end
  if start_pos[1] > end_pos[1]
      or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
    start_pos, end_pos = end_pos, start_pos
  end

  local start_line = start_pos[1] - 1
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_pos[1], false)
  if #lines == 0 then return nil, nil end

  -- Handle character-wise (v) and block-wise (^V) visual mode
  if visual_mode == "v" or visual_mode == "\22" then
    lines[1] = string.sub(lines[1], start_pos[2] + 1)
    if #lines == 1 then
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] - start_pos[2] + 1)
    else
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
    end
  end

  -- Line-wise (V) visual mode: start_pos[2] is already 0, lines are full
  -- No adjustment needed for line-wise

  return table.concat(lines, "\n"), start_line
end

--- Show a braille spinner in the bottom-right corner.
function Utils.show_spinner()
  if spinner_win and vim.api.nvim_win_is_valid(spinner_win) then
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    { config.options.spinner_characters[1], })

  spinner_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = 1,
    height = 1,
    row = vim.o.lines - 3 - vim.o.cmdheight,
    col = vim.o.columns - 2,
    style = "minimal",
    noautocmd = true,
  })

  vim.api.nvim_set_option_value("winhl", "Normal:AskaiSpinner",
    { win = spinner_win, })

  spinner_idx = 1
  spinner_timer = vim.loop.new_timer()
  if spinner_timer then
    spinner_timer:start(
      config.options.spinner_interval_ms,
      config.options.spinner_interval_ms,
      vim.schedule_wrap(function()
        if not spinner_win
            or not vim.api.nvim_win_is_valid(spinner_win) then return end
        spinner_idx
          = (spinner_idx % #config.options.spinner_characters) + 1
        local buf = vim.api.nvim_win_get_buf(spinner_win)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false,
          { config.options.spinner_characters[spinner_idx], })
      end))
  end
end

--- Hide and clean up the spinner.
function Utils.hide_spinner()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
  if spinner_win and vim.api.nvim_win_is_valid(spinner_win) then
    pcall(vim.api.nvim_win_close, spinner_win, true)
    spinner_win = nil
  end
end

--- Apply edits to a buffer. Replaces all occurrences of each oldString.
---@param buf integer
---@param edits { oldString: string, newString: string }[]
---@return boolean ok
---@return string? err
function Utils.apply_edits(buf, edits)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")

  for _, e in ipairs(edits) do
    local first = content:find(e.oldString, 1, true)
    if not first then
      return false, "oldString not found in file:\n```\n" .. e.oldString .. "\n```"
    end
    content = content:gsub(vim.pesc(e.oldString), e.newString)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    vim.split(content, "\n", { plain = true, }))
  return true
end

--- Get visual selection context for AI request.
--- Returns selected_text (empty if no valid selection) and full_file.
---@param buf integer
---@param line? integer range start (0 if no range)
---@return { selected_text: string, full_file: string, filetype: string }
function Utils.get_visual_context(buf, line)
  local full_file = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local filetype = vim.bo[buf].filetype

  -- Determine if we have a visual selection:
  -- 1. Explicit range from command (:'<,'>AskAI) -> line > 0
  -- 2. Called directly from visual mode keymap -> currently in visual mode
  -- Otherwise, ignore stale marks from previous visual selections
  local mode = vim.api.nvim_get_mode().mode
  local has_selection = false
  if line and line > 0 then
    has_selection = true
  elseif mode == "v" or mode == "V" or mode == "\22" then
    has_selection = true
  end

  local selected_text = ""
  if has_selection then
    selected_text = Utils.get_visual_selection(buf) or ""
    -- If selection is empty (stale marks), treat as no selection
    if selected_text == "" then
      has_selection = false
    end
  end

  return {
    selected_text = selected_text,
    full_file = full_file,
    filetype = filetype,
  }
end

return Utils
