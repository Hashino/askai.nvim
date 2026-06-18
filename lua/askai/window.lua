local config = require("askai.config")
local utils  = require("askai.utils")

---@class askai.Window [Hashino/askai.nvim] floating window management
local Window = {
  win_id = nil,
}

--- closes the response window if it is open
local function close()
  if Window.win_id and vim.api.nvim_win_is_valid(Window.win_id) then
    pcall(vim.api.nvim_win_close, Window.win_id, true)
  end
  Window.win_id = nil
end

--- highlights `- `/`+ ` diff lines in the buffer
---@param buf integer
---@param lines string[]
local function highlight_diff(buf, lines)
  local ns = vim.api.nvim_create_namespace("askai_diff")
  for i, line in ipairs(lines) do
    local hl = (line:match("^%- ") and "AskaiDiffDelete")
      or (line:match("^%+ ") and "AskaiDiffAdd")
    if hl then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { hl_group = hl, end_row = i, })
    end
  end
end

--- creates and opens the response buffer and window
---@param content string
---@param filetype? string filetype for syntax highlighting (diff only)
---@param is_diff boolean whether the content is a diff or a markdown summary
---@return integer buf
function Window.create_window(content, filetype, is_diff)
  close()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf, })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf, })

  local lines = vim.split(content, "\n", { plain = true, })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  if is_diff then
    if filetype and filetype ~= "" then
      vim.api.nvim_set_option_value("filetype", filetype, { buf = buf, })
      pcall(vim.treesitter.start, buf, filetype)
    end
    highlight_diff(buf, lines)
  else
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf, })
    vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf, })
  end

  vim.keymap.set("n", config.options.keys.dismiss, close, { buffer = buf, })

  Window.win_id = vim.api.nvim_open_win(buf, true, config.options.win_config)

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function() Window.win_id = nil end,
  })

  return buf
end

--- adds the confirm keymap and winbar to a diff window
---@param buf integer response buffer
---@param toedit integer buffer the edits apply to
---@param edits { oldString: string, newString: string, all: boolean }[]
function Window.setup_diff_window(buf, toedit, edits)
  if not Window.win_id then return end

  vim.keymap.set("n", config.options.keys.confirm, function()
    close()
    if vim.api.nvim_buf_is_valid(toedit) and vim.api.nvim_buf_is_loaded(toedit) then
      local ok, err = utils.apply_edits(toedit, edits)
      if not ok then
        vim.notify("[askai.nvim] failed to apply edits: " .. err, vim.log.levels.ERROR)
      end
    end
  end, { buffer = buf, })

  vim.api.nvim_set_option_value("winbar",
    string.format(" [AskAI] %s to accept | %s to dismiss",
      config.options.keys.confirm, config.options.keys.dismiss),
    { win = Window.win_id, })
end

--- adds the dismiss-only winbar to a summary window
function Window.setup_summary_window()
  if not Window.win_id then return end

  vim.api.nvim_set_option_value("winbar",
    string.format(" [AskAI] %s to dismiss", config.options.keys.dismiss),
    { win = Window.win_id, })
end

return Window
