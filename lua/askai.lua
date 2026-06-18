local config = require("askai.config")
local ai     = require("askai.ai")
local utils  = require("askai.utils")
local window = require("askai.window")

---@class askai.AskAI [Hashino/askai.nvim] main module
---@field _initialized boolean whether the plugin was properly set up
local AskAI  = {
  _initialized = false,
}

--- setup askai.nvim
---@param opts? askai.Config
function AskAI.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if config.options.provider.api_url == ""
      or config.options.provider.model == ""
      or config.options.provider.api_key == "" then
    vim.notify("[askai.nvim] provider.api_url, provider.model and api_key must be set",
      vim.log.levels.ERROR)
    AskAI._initialized = false
    return
  end

  ai.validate_provider(function(validation)
    if not validation.success then
      vim.notify("[askai.nvim] provider validation failed: " .. validation.error,
        vim.log.levels.ERROR)
      AskAI._initialized = false
      return
    end

    for group, spec in pairs(config.options.highlights) do
      if type(spec) == "string" then
        pcall(vim.api.nvim_set_hl, 0, group, { link = spec, })
      elseif type(spec) == "table" then
        pcall(vim.api.nvim_set_hl, 0, group, spec)
      end
    end

    AskAI._initialized = true
  end)
end

--- main entry point: ask the AI a question with the current buffer as context.
---
--- `selection` is the selected code to focus on. when omitted, it is detected
--- automatically: if the editor is currently in visual mode the live selection
--- is captured, otherwise the request has no selection. the `:AskAI` command
--- passes its range text explicitly through this argument.
---@param question? string
---@param selection? string selected code (auto-detected from visual mode if nil)
function AskAI.ask(question, selection)
  if not AskAI._initialized then
    vim.notify(
      "[askai.nvim] plugin not initialized. call askai.setup() with a valid config first.",
      vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  if selection == nil then
    selection = utils.get_visual_selection(buf)
  end

  if question == nil or question == "" then
    question = vim.fn.input("Ask AI: ")
    if question == "" then return end
  end

  local context = {
    question = question,
    selected_text = selection or "",
    full_file = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
    filetype = vim.bo[buf].filetype,
  }

  utils.show_spinner()

  ai.classify(question, function(intent)
    local ask = intent == "action" and ai.ask_action or ai.ask_explain
    ask(context, function(resp)
      utils.hide_spinner()
      if resp and resp.edits then
        local wbuf = window.create_window(utils.build_diff(resp.edits), context.filetype, true)
        window.setup_diff_window(wbuf, buf, resp.edits)
      elseif resp and resp.summary then
        window.create_window(resp.summary, nil, false)
        window.setup_summary_window()
      else
        vim.notify("[askai.nvim] no response from AI", vim.log.levels.WARN)
      end
    end)
  end)
end

return AskAI
