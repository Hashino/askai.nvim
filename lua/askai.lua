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

--- Apply edit(s) to a buffer. Validates oldString uniqueness, replaces all
--- edits in memory first, then writes the buffer once (single undo point).
---@param buf integer
---@param edits { oldString: string, newString: string }[]
---@return boolean ok
---@return string? err
local function apply_edits(buf, edits)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")

  for _, e in ipairs(edits) do
    local first = content:find(e.oldString, 1, true)
    if not first then
      return false, "oldString not found in file:\n```\n" .. e.oldString .. "\n```"
    end
    local second = content:find(e.oldString, first + 1, true)
    if second then
      return false, "oldString appears multiple times; provide more context"
    end
    content = content:sub(1, first - 1) .. e.newString .. content:sub(first + #e.oldString)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    vim.split(content, "\n", { plain = true, }))
  return true
end

--- Show a floating window with the AI response or diff preview.
---@param toedit integer buffer to apply edits to
---@param response { summary?: string, edit?: { oldString: string, newString: string }, edits?: { oldString: string, newString: string }[] }
function AskAI.show(toedit, response)
  if not response then return end
  if not response.summary and not response.edit and not response.edits then return end

  -- Collect edits and build window content
  ---@type { oldString: string, newString: string }[]
  local edits = {}
  ---@type string
  local content_str

  if response.edit then
    edits = { response.edit, }
  elseif response.edits then
    ---@type { oldString: string, newString: string }[]
    edits = response.edits
  end

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
    content_str = table.concat(parts, "\n")
  else
    content_str = response.summary
  end

  ---@diagnostic disable-next-line: param-type-mismatch
  local trimmed = vim.trim(content_str)
  if trimmed == "" then
    vim.notify("[askai.nvim] AI returned an empty response", vim.log.levels.WARN)
    return
  end
  content_str = trimmed

  if AskAI.win_id and vim.api.nvim_win_is_valid(AskAI.win_id) then
    pcall(vim.api.nvim_win_close, AskAI.win_id, true)
    AskAI.win_id = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf, })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf, })

  local summary_lines = vim.split(content_str, "\n", { plain = true, })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, summary_lines)

  -- Apply diff highlights when showing edits
  if #edits > 0 then
    local ft = vim.bo[toedit].filetype
    if ft and ft ~= "" then
      vim.api.nvim_set_option_value("filetype", ft, { buf = buf, })
      pcall(vim.treesitter.start, buf, ft)
    end
    local ns = vim.api.nvim_create_namespace("askai_diff")
    local lines = vim.split(content_str, "\n", { plain = true, })
    for i, line in ipairs(lines) do
      if line:match("^%- ") then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          hl_group = "AskaiDiffDelete",
          end_row = i - 1 + 1,
        })
      elseif line:match("^%+ ") then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          hl_group = "AskaiDiffAdd",
          end_row = i - 1 + 1,
        })
      end
    end
  else
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf, })
    vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf, })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("doautocmd FileType markdown")
      if vim.treesitter and vim.treesitter.start then
        pcall(vim.treesitter.start, buf, "markdown")
      end
    end)
  end

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

  if #edits > 0 then
    local ft = vim.bo[toedit].filetype
    if ft and ft ~= "" then
      vim.api.nvim_set_option_value("filetype", ft, { buf = buf, })
      pcall(vim.treesitter.start, buf, ft)
    end
    vim.keymap.set("n", config.options.keys.confirm, function()
      pcall(vim.api.nvim_win_close, AskAI.win_id, true)
      AskAI.win_id = nil
      if vim.api.nvim_buf_is_valid(toedit)
          and vim.api.nvim_buf_is_loaded(toedit) then
        local ok, err = apply_edits(toedit, edits)
        if not ok then
          vim.notify("[askai.nvim] failed to apply edits: " .. err, vim.log.levels.ERROR)
        end
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
---@param line? integer range start (0 if no range)
function AskAI.ask(question, line)
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
    selected_text = utils.get_visual_selection(buf) or ""
  end

  local full_file = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local filetype = vim.bo[buf].filetype

  local context = {
    question = question,
    selected_text = selected_text,
    full_file = full_file,
    filetype = filetype,
  }

  utils.show_spinner()

  ai.classify(question, function(intent)
    if intent == "action" then
      ai.ask_action(context, function(resp)
        utils.hide_spinner()
        if resp and (resp.edit or resp.edits) then
          AskAI.show(buf, resp)
        elseif resp and resp.summary then
          AskAI.show(buf, resp)
        else
          vim.notify("[askai.nvim] No response from AI", vim.log.levels.WARN)
        end
      end)
    else
      ai.ask_explain(context, function(resp)
        utils.hide_spinner()
        if resp and resp.summary then
          AskAI.show(buf, resp)
        else
          vim.notify("[askai.nvim] No response from AI", vim.log.levels.WARN)
        end
      end)
    end
  end)
end

return AskAI
