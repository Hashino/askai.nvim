local config = require("askai.config")

---@class askai.Utils [Hashino/askai.nvim] utilities

local Utils = {}

-- Spinner state (internal)
local spinner_win = nil ---@type integer?
local spinner_timer = nil
local spinner_idx = 1 ---@type integer

--- Extract visual selection text and its 0-indexed start line.
---@param buf integer buffer handle
---@return string|nil, integer|nil
function Utils.get_visual_selection(buf)
  local mode = vim.fn.visualmode()

  if not mode or mode == "" then
    local cur = vim.api.nvim_get_mode().mode
    if cur == "v" or cur == "V" then
      mode = cur
    elseif cur == "\22" then
      mode = "\22"
    else
      return nil, nil
    end
  end

  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return nil, nil
  end

  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  -- Verify we're still in visual mode (marks persist after exiting)
  if not vim.fn.visualmode() or vim.fn.visualmode() == "" then
    return nil, nil
  end

  if start_pos[1] == 0 and end_pos[1] == 0 then
    local v_start = vim.fn.getpos("v")
    local v_end = vim.fn.getpos(".")
    start_pos = { v_start[2], v_start[3] - 1 }
    end_pos = { v_end[2], v_end[3] - 1 }
  end

  if mode == "V" then start_pos[2] = 0 end

  if start_pos[1] > end_pos[1]
      or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
    start_pos, end_pos = end_pos, start_pos
  end

  local start_line = start_pos[1] - 1

  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_pos[1], false)
  if #lines == 0 then return nil, nil end

  if mode == "v" or mode == "\22" then
    lines[1] = string.sub(lines[1], start_pos[2] + 1)
    if #lines == 1 then
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] - start_pos[2] + 1)
    else
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
    end
  end

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

return Utils
