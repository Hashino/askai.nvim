local config = require("askai.config")
local ai     = require("askai.ai")
local utils  = require("askai.utils")

---@class askai.AskAI [Hashino/askai.nvim] main module

local AskAI  = {
  win_id = nil,

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
    vim.notify("[askai.nvim] provider.api_url, provider.model and api_key must be set", vim.log.levels.ERROR)
    AskAI._initialized = false
    return
  end

  local validation = ai.validate_provider()
  if not validation.success then
    vim.notify("[askai.nvim] provider validation failed: " .. validation.error,
      vim.log.levels.ERROR)
    AskAI._initialized = false
    return
  end

  AskAI.augroup = vim.api.nvim_create_augroup("AskAI", { clear = true, })

  for group, spec in pairs(config.options.highlights) do
    if type(spec) == "string" then
      pcall(vim.api.nvim_set_hl, 0, group, { link = spec, })
    elseif type(spec) == "table" then
      pcall(vim.api.nvim_set_hl, 0, group, spec)
    end
  end

  vim.notify("[askai.nvim] provider validated successfully", vim.log.levels.INFO)
  AskAI._initialized = true
end

--- Show a floating window with the AI response.
---@param toedit integer buffer to apply edits to
---@param response { summary: string, edit?: { start: integer, final: integer, content: string[] } }
function AskAI.show(toedit, response)
  if not response or not response.summary then return end

  local trimmed = vim.trim(response.summary)
  if trimmed == "" then
    vim.notify("[askai.nvim] AI returned an empty response", vim.log.levels.WARN)
    return
  end
  response.summary = trimmed

  if AskAI.win_id and vim.api.nvim_win_is_valid(AskAI.win_id) then
    pcall(vim.api.nvim_win_close, AskAI.win_id, true)
    AskAI.win_id = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf, })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf, })

  local summary_lines = vim.split(response.summary, "\n", { plain = true, })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, summary_lines)

  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf, })
  vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf, })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("doautocmd FileType markdown")
    if vim.treesitter and vim.treesitter.start then
      pcall(vim.treesitter.start, buf, "markdown")
    end
  end)

  vim.keymap.set("n", config.options.keys.dismiss, function()
    if AskAI.win_id and vim.api.nvim_win_is_valid(AskAI.win_id) then
      pcall(vim.api.nvim_win_close, AskAI.win_id, true)
      AskAI.win_id = nil
    end
  end, { buffer = buf, })

  ---@diagnostic disable-next-line: param-type-mismatch
  AskAI.win_id = vim.api.nvim_open_win(buf, true, config.options.win_config)

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function() AskAI.win_id = nil end,
  })

  local edit = response.edit
  if edit and type(edit.start) == "number" and type(edit.final) == "number"
      and type(edit.content) == "table" then
    vim.keymap.set("n", config.options.keys.confirm, function()
      pcall(vim.api.nvim_win_close, AskAI.win_id, true)
      AskAI.win_id = nil
      if vim.api.nvim_buf_is_valid(toedit)
          and vim.api.nvim_buf_is_loaded(toedit) then
        vim.api.nvim_buf_set_lines(toedit, edit.start, edit.final, false,
          edit.content)
      end
    end, { buffer = buf, })

    vim.api.nvim_set_option_value("winbar",
      string.format(" [AskAI] %s to accept | %s to dismiss",
        config.options.keys.confirm, config.options.keys.dismiss),
      { win = AskAI.win_id, })
  else
    vim.api.nvim_set_option_value("winbar",
      string.format(" [AskAI] %s to dismiss", config.options.keys.dismiss),
      { win = AskAI.win_id, })
  end
end

--- Main entry point: ask the AI a question with context.
---@param question? string
function AskAI.ask(question)
  if not AskAI._initialized then
    vim.notify("[askai.nvim] Plugin not initialized. Call askai.setup() first.",
      vim.log.levels.ERROR)
    return
  end

  if question == nil or question == "" then
    question = vim.fn.input("Ask AI: ")
    if question == "" then return end
  end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end

  local selected_text, sel_start_line = utils.get_visual_selection(buf)
  selected_text = selected_text or ""

  local full_file = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local filetype = vim.bo[buf].filetype

  utils.show_spinner()

  ai.ask_with_tools({
    question = question,
    selected_text = selected_text,
    sel_start_line = sel_start_line,
    full_file = full_file,
    filetype = filetype,
  }, function(resp)
    utils.hide_spinner()
    if resp and resp.summary then
      AskAI.show(buf, resp)
    else
      vim.notify("[askai.nvim] No response from AI", vim.log.levels.WARN)
    end
  end)
end

return AskAI
