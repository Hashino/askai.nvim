local config = require("askai.config")

---@class askai.Utils [Hashino/askai.nvim] utilities

local Utils = {}

-- Spinner state (internal)
local spinner_win = nil ---@type integer?
local spinner_timer = nil
local spinner_idx = 1 ---@type integer

--- Extract the text the user is selecting *right now*.
--- Returns nil unless the editor is currently in visual mode, so stale `<`/`>`
--- marks from a previous selection can never leak into a later request.
--- Reads the live endpoints with `getpos("v")` (selection start) and
--- `getpos(".")` (cursor), which are valid while visual mode is active.
---@param buf integer buffer handle
---@return string|nil selection
function Utils.get_visual_selection(buf)
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end

  local s = vim.fn.getpos("v")
  local e = vim.fn.getpos(".")
  local s_line, s_col = s[2], s[3]
  local e_line, e_col = e[2], e[3]

  -- Ensure start <= end (the cursor may be before the anchor)
  if s_line > e_line or (s_line == e_line and s_col > e_col) then
    s_line, e_line = e_line, s_line
    s_col, e_col = e_col, s_col
  end

  local lines = vim.api.nvim_buf_get_lines(buf, s_line - 1, e_line, false)
  if #lines == 0 then return nil end

  -- Line-wise (V): whole lines, columns are irrelevant
  if mode == "V" then
    return table.concat(lines, "\n")
  end

  -- Char-wise (v) and block-wise (^V, approximated as a char span)
  if #lines == 1 then
    lines[1] = string.sub(lines[1], s_col, e_col)
  else
    lines[1] = string.sub(lines[1], s_col)
    lines[#lines] = string.sub(lines[#lines], 1, e_col)
  end
  return table.concat(lines, "\n")
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

--- Apply edits to a buffer.
--- When e.all is true, replaces ALL occurrences of oldString.
--- When e.all is false, replaces only the FIRST occurrence.
---@param buf integer
---@param edits { oldString: string, newString: string, all: boolean }[]
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
    if e.all then
      content = content:gsub(vim.pesc(e.oldString), e.newString)
    else
      local before = content:sub(1, first - 1)
      local after = content:sub(first + #e.oldString)
      content = before .. e.newString .. after
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    vim.split(content, "\n", { plain = true, }))
  return true
end

--- Build diff content string from edits.
---@param edits { oldString: string, newString: string, all: boolean }[]
---@param summary? string
---@return string content
function Utils.build_diff(edits, summary)
  if #edits > 0 then
    local parts = {}
    for i, e in ipairs(edits) do
      if i > 1 then table.insert(parts, "") end
      for _, l in ipairs(vim.split(e.oldString, "\n", { plain = true, })) do
        table.insert(parts, "- " .. l)
      end
      for _, l in ipairs(vim.split(e.newString, "\n", { plain = true, })) do
        table.insert(parts, "+ " .. l)
      end
    end
    return table.concat(parts, "\n")
  else
    return summary or ""
  end
end

return Utils
