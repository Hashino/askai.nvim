local config = require("askai.config")
local utils  = require("askai.utils")

---@class askai.Window [Hashino/askai.nvim] floating window management
local M = {
  win_id = nil,
}

--- Create and configure the response buffer and window.
---@param content string
---@param filetype? string
---@param is_diff boolean
---@return integer buf, integer win_id
function M.create_window(content, filetype, is_diff)
  -- Close existing window if open
  if M.win_id and vim.api.nvim_win_is_valid(M.win_id) then
    pcall(vim.api.nvim_win_close, M.win_id, true)
    M.win_id = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

  local lines = vim.split(content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Apply highlighting
  if is_diff then
    if filetype and filetype ~= "" then
      vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
      pcall(vim.treesitter.start, buf, filetype)
    end
    local ns = vim.api.nvim_create_namespace("askai_diff")
    for i, line in ipairs(lines) do
      if line:match("^%- ") then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          hl_group = "AskaiDiffDelete",
          end_row = i,
        })
      elseif line:match("^%+ ") then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          hl_group = "AskaiDiffAdd",
          end_row = i,
        })
      end
    end
  else
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
    vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("doautocmd FileType markdown")
      if vim.treesitter and vim.treesitter.start then
        pcall(vim.treesitter.start, buf, "markdown")
      end
    end)
  end

  -- Dismiss keymap
  vim.keymap.set("n", config.options.keys.dismiss, function()
    if M.win_id and vim.api.nvim_win_is_valid(M.win_id) then
      pcall(vim.api.nvim_win_close, M.win_id, true)
      M.win_id = nil
    end
  end, { buffer = buf })

  -- Open window
  M.win_id = vim.api.nvim_open_win(buf, true, config.options.win_config)

  -- WinClosed autocmd
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function()
      M.win_id = nil
    end,
  })

  return buf, M.win_id
end

--- Setup diff window with confirm keymap and winbar.
---@param buf integer
---@param toedit integer
---@param edits { oldString: string, newString: string }[]
function M.setup_diff_window(buf, toedit, edits)
  if not M.win_id then return end

  vim.keymap.set("n", config.options.keys.confirm, function()
    if M.win_id then
      pcall(vim.api.nvim_win_close, M.win_id, true)
      M.win_id = nil
    end
    if vim.api.nvim_buf_is_valid(toedit)
        and vim.api.nvim_buf_is_loaded(toedit) then
      local ok, err = utils.apply_edits(toedit, edits)
      if not ok then
        vim.notify("[askai.nvim] failed to apply edits: " .. err, vim.log.levels.ERROR)
      end
    end
  end, { buffer = buf })

  vim.api.nvim_set_option_value("winbar",
    string.format(" [AskAI] %s to accept | %s to dismiss",
      config.options.keys.confirm, config.options.keys.dismiss),
    { win = M.win_id })
end

--- Setup summary window with dismiss-only winbar.
---@param buf integer
function M.setup_summary_window(buf)
  if not M.win_id then return end

  vim.api.nvim_set_option_value("winbar",
    string.format(" [AskAI] %s to dismiss", config.options.keys.dismiss),
    { win = M.win_id })
end

return M