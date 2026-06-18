local config = require("askai.config")
local ai     = require("askai.ai")
local utils  = require("askai.utils")
local window = require("askai.window")

-- provider validation can hit a transient error (e.g. a 5xx); retry a few times
-- before giving up so one hiccup doesn't disable the whole session.
local VALIDATE_ATTEMPTS = 3
local VALIDATE_INTERVAL_MS = 3000

---@alias askai.State
---| "not" setup() has not been called yet
---| "initializing" setup() is validating the provider
---| "error" setup() ran but the plugin could not be initialized
---| "initialized" ready to use

---@class askai.AskAI [Hashino/askai.nvim] main module
---@field _state askai.State plugin initialization state
local AskAI  = {
  _state = "not",
}

--- applies the configured highlight groups
local function apply_highlights()
  for group, spec in pairs(config.options.highlights) do
    if type(spec) == "string" then
      pcall(vim.api.nvim_set_hl, 0, group, { link = spec, })
    elseif type(spec) == "table" then
      pcall(vim.api.nvim_set_hl, 0, group, spec)
    end
  end
end

--- setup askai.nvim
---@param opts? askai.Config
function AskAI.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if config.options.provider.api_url == ""
      or config.options.provider.model == ""
      or config.options.provider.api_key == "" then
    vim.notify("[askai.nvim] provider.api_url, provider.model and api_key must be set",
      vim.log.levels.ERROR)
    AskAI._state = "error"
    return
  end

  AskAI._state = "initializing"

  local function attempt(n)
    ai.validate_provider(function(validation)
      if validation.success then
        apply_highlights()
        AskAI._state = "initialized"
      elseif n < VALIDATE_ATTEMPTS then
        vim.defer_fn(function() attempt(n + 1) end, VALIDATE_INTERVAL_MS)
      else
        vim.notify("[askai.nvim] provider validation failed: " .. validation.error,
          vim.log.levels.ERROR)
        AskAI._state = "error"
      end
    end)
  end

  attempt(1)
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
  if AskAI._state ~= "initialized" then
    local hint = {
      ["not"] = {
        "askai.setup() was not called — add require(\"askai\").setup({ ... }) to your config",
        vim.log.levels.ERROR,
      },
      initializing = {
        "askai is still initializing, wait a moment and try again",
        vim.log.levels.WARN,
      },
      error = {
        "askai failed to initialize — check your provider config (see :messages)",
        vim.log.levels.ERROR,
      },
    }
    local h = hint[AskAI._state]
    vim.notify("[askai.nvim] " .. h[1], h[2])
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
