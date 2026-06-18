local config = require("askai.config")

---@class askai.AI [Hashino/askai.nvim] AI provider requests
local AI = {}


---@param body table
---@param is_anthropic boolean
---@return string|nil
local function extract_content(body, is_anthropic)
  if is_anthropic then
    if body.content then
      for _, block in ipairs(body.content) do
        if block.type == "text" then
          return block.text
        end
      end
    end
    return nil
  end
  local msg = body.choices and body.choices[1] and body.choices[1].message
  if msg then
    if type(msg.content) == "string" then
      return msg.content
    end
    if type(msg.reasoning) == "string" then
      return msg.reasoning
    end
  end
  return nil
end

--- Extract all tool calls from the API response.
---@param decoded table
---@param is_anthropic boolean
---@return { name: string, arguments: table }[]
local function extract_tool_calls(decoded, is_anthropic)
  local calls = {}
  if is_anthropic then
    if decoded.content then
      for _, block in ipairs(decoded.content) do
        if block.type == "tool_use" then
          table.insert(calls, { name = block.name, arguments = block.input, })
        end
      end
    end
  else
    local msg = decoded.choices and decoded.choices[1] and decoded.choices[1].message
    if msg and msg.tool_calls then
      for _, call in ipairs(msg.tool_calls) do
        if call.type == "function" and call["function"] then
          local ok, args = pcall(vim.json.decode, call["function"].arguments)
          if ok then
            table.insert(calls, { name = call["function"].name, arguments = args, })
          end
        end
      end
    end
  end
  return calls
end

--- Build HTTP request headers and body. Optionally includes tool definitions.
---@param prompt string
---@param tools? table[]
---@return table, string, boolean
local function build_request(prompt, tools)
  local is_anthropic = config.options.provider.api_url:find("anthropic.com", 1, true) ~= nil

  local headers = { ["Content-Type"] = "application/json", }
  local body

  if is_anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"

    local request = {
      model = config.options.provider.model,
      max_tokens = 4096,
      messages = { { role = "user", content = prompt, }, },
    }

    if tools then
      request.tools = tools
      request.tool_choice = { type = "auto", }
    end

    body = vim.json.encode(request)
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key

    local request = {
      model = config.options.provider.model,
      messages = { { role = "user", content = prompt, }, },
    }

    if tools then
      request.tools = tools
      request.tool_choice = "auto"
    end

    body = vim.json.encode(request)
  end

  return headers, body, is_anthropic
end

--- Build the `edit` tool definition in the provider's format.
---@param is_anthropic boolean
---@return table
local function build_edit_tool(is_anthropic)
  local schema = {
    type = "object",
    properties = {
      oldString = {
        type = "string",
        description = "The EXACT text to find in the file. Must match whitespace and line breaks exactly. Must be unique in the file.",
      },
      newString = {
        type = "string",
        description = "The replacement text",
      },
    },
    required = { "oldString", "newString", },
  }

  if is_anthropic then
    return {
      name = "edit",
      description = "Edit code by replacing exact text. If the oldString appears in multiple places, ALL occurrences will be replaced.",
      input_schema = schema,
    }
  end

  return {
    type = "function",
    ["function"] = {
      name = "edit",
      description = "Edit code by replacing exact text. If the oldString appears in multiple places, ALL occurrences will be replaced.",
      parameters = schema,
    },
  }
end

--- Build the `explain` tool definition in the provider's format.
---@param is_anthropic boolean
---@return table
local function build_explain_tool(is_anthropic)
  local schema = {
    type = "object",
    properties = {
      summary = {
        type = "string",
        description = "Markdown explanation answering the user's question",
      },
    },
    required = { "summary", },
  }

  if is_anthropic then
    return {
      name = "explain",
      description = "Explain code or answer a question about the code. Use this when the user asks a question, wants an explanation, or wants to understand code.",
      input_schema = schema,
    }
  end

  return {
    type = "function",
    ["function"] = {
      name = "explain",
      description = "Explain code or answer a question about the code. Use this when the user asks a question, wants an explanation, or wants to understand code.",
      parameters = schema,
    },
  }
end

--- Classify user intent as "action" or "informational".
---@param question string
---@param callback fun(intent: string)
function AI.classify(question, callback)
  local classify_prompt = [[Classify the user request as "action" or "informational".
Reply with exactly one word: "action" or "informational".

- "action": user wants to MODIFY code (add, change, remove, fix, refactor, insert, delete, update).
- "informational": user wants to UNDERSTAND code (explain, how, why, what, describe, question).

Examples:
User: add emojis to all notifications -> action
User: explain this function -> informational
User: fix the bug in line 10 -> action
User: what is this file about? -> informational
User: how does this work? -> informational
User: refactor this code -> action
User: why is this slow? -> informational
User: remove the unused variable -> action

User: ]] .. question

  local headers, body, is_anthropic = build_request(classify_prompt)

  local cmd = { "curl", "-sS", "-X", "POST", config.options.provider.api_url, }
  for k, v in pairs(headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body)

  local done = false
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data, _)
      if done then return end
      if not data then callback("action"); return end
      vim.schedule(function()
        if done then return end
        done = true
        local output = table.concat(data, "")
        local ok, decoded = pcall(vim.json.decode, output)
        if not ok then callback("action"); return end
        local content = extract_content(decoded, is_anthropic)
        if type(content) ~= "string" then callback("action"); return end
        local intent = content:match("^(action)$") or content:match("^(informational)$")
        callback(intent or "action")
      end)
    end,
    on_stderr = function(_, _, _)
      if done then return end
      done = true
      vim.schedule(function() callback("action") end)
    end,
  })
end

--- Make an AI request with tool definitions and return tool calls.
---@param prompt string
---@param callback fun(response: { name: string, arguments: table }[]|table|nil)
---@param tools? table[]
function AI.ask(prompt, callback, tools)
  local headers, body, is_anthropic = build_request(prompt, tools)

  local cmd = { "curl", "-sS", "-X", "POST", config.options.provider.api_url, }
  for k, v in pairs(headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body)

  local done = false
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data, _)
      if done then return end
      if not data then return end

      vim.schedule(function()
        if done then return end
        done = true

        local output = table.concat(data, "")

        if output == nil or vim.trim(output) == "" then
          callback({
            summary = "The AI provider returned an empty response.\n\n"
              .. "Check that your **api_url** is correct and your network can reach it.\n\n"
              .. "Current url: `" .. config.options.provider.api_url .. "`",
          })
          return
        end

        local ok, decoded = pcall(vim.json.decode, output)
        if not ok then
          callback({ summary = "Could not parse API response:\n```\n" .. output .. "\n```", })
          return
        end

        -- Tool calling path
        local tool_calls = extract_tool_calls(decoded, is_anthropic)
        if #tool_calls > 0 then
          callback(tool_calls)
          return
        end

        -- Content-only fallback
        local content = extract_content(decoded, is_anthropic)
        if type(content) == "string" and content ~= "" then
          callback({ summary = content, })
        else
          callback({
            summary = "The AI returned an empty response.\n\n"
              .. "Raw API response:\n```json\n" .. output .. "\n```",
          })
        end
      end)
    end,
    on_stderr = function(_, data, _)
      if done then return end
      if not data then return end
      vim.schedule(function()
        if done then return end
        done = true
        local err = table.concat(data, "")
        if err and err ~= "" then
          callback({ summary = "Request error:\n```\n" .. err .. "\n```", })
        else
          callback({ summary = "No response from AI.", })
        end
      end)
    end,
  })
end

--- Action: prompt + edit tool only.
---@param context { question: string, selected_text?: string, full_file: string, filetype: string }
---@param callback fun(response: table|nil)
function AI.ask_action(context, callback)
  local is_anthropic = config.options.provider.api_url:find("anthropic.com", 1, true) ~= nil
  local ft = context.filetype or ""

  local prompt
  if context.selected_text and context.selected_text ~= "" then
    prompt = "Question: " .. context.question .. "\n\n"
      .. "Selected text:\n```" .. ft .. "\n" .. context.selected_text .. "\n```\n\n"
      .. "Full file (context only):\n```" .. ft .. "\n" .. context.full_file .. "\n```\n\n"
      .. "CRITICAL: You must ONLY edit within the selected text shown above.\n"
      .. "The full file is for context only — do NOT change code outside the selected region."
  else
    prompt = "Question: " .. context.question .. "\n\n"
      .. "File:\n```" .. ft .. "\n" .. context.full_file .. "\n```"
  end

  prompt = prompt .. "\n\nThe `edit` tool replaces EXACT text. `oldString` must match the"
    .. "\nfile content exactly (whitespace, line breaks). If it appears in"
    .. "\nmultiple places, ALL occurrences will be replaced."
    .. "\n"
    .. "\nTo change similar text in multiple places, provide one `edit`"
    .. "\ncall with the exact text to find — it will replace ALL matches."

  AI.ask(prompt, function(resp)
    if not resp then callback(nil); return end
    if type(resp) == "table" and resp[1] then
      local edits = {}
      for _, tc in ipairs(resp) do
        if tc.name == "edit" then
          table.insert(edits, { oldString = tc.arguments.oldString, newString = tc.arguments.newString, })
        end
      end
      if #edits > 0 then
        callback({ edits = edits, })
      else
        callback(nil)
      end
      return
    end
    callback(resp)
  end, { build_edit_tool(is_anthropic), })
end

--- Informational: prompt + explain tool only.
---@param context { question: string, selected_text?: string, full_file: string, filetype: string }
---@param callback fun(response: table|nil)
function AI.ask_explain(context, callback)
  local is_anthropic = config.options.provider.api_url:find("anthropic.com", 1, true) ~= nil
  local ft = context.filetype or ""

  local prompt
  if context.selected_text and context.selected_text ~= "" then
    prompt = "Question: " .. context.question .. "\n\n"
      .. "Selected text:\n```" .. ft .. "\n" .. context.selected_text .. "\n```\n\n"
      .. "Full file (context only):\n```" .. ft .. "\n" .. context.full_file .. "\n```\n\n"
      .. "Explain the selected code. The full file is for context."
  else
    prompt = "Question: " .. context.question .. "\n\n"
      .. "File:\n```" .. ft .. "\n" .. context.full_file .. "\n```"
  end

  prompt = prompt .. "\n\nAlways use fenced code blocks with language annotation (e.g., ```lua, ```python) in your responses."

  AI.ask(prompt, function(resp)
    if not resp then callback(nil); return end
    if type(resp) == "table" and resp[1] then
      local explains = {}
      for _, tc in ipairs(resp) do
        if tc.name == "explain" then
          table.insert(explains, tc.arguments.summary)
        end
      end
      if #explains > 0 then
        callback({ summary = table.concat(explains, "\n\n---\n\n"), })
      else
        callback(nil)
      end
      return
    end
    callback(resp)
  end, { build_explain_tool(is_anthropic), })
end

--- Make an async test request to validate provider config.
---@param callback fun(result: { success: boolean, error?: string })
function AI.validate_provider(callback)
  local test_prompt = "Reply with exactly: OK"
  local headers, body, is_anthropic = build_request(test_prompt)

  local cmd = { "curl", "-sS", "-X", "POST", config.options.provider.api_url, }
  for k, v in pairs(headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body)

  local stdout_data = {}
  local stderr_data = {}

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data, _)
      if data then
        for _, line in ipairs(data) do
          table.insert(stdout_data, line)
        end
      end
    end,
    on_stderr = function(_, data, _)
      if data then
        for _, line in ipairs(data) do
          table.insert(stderr_data, line)
        end
      end
    end,
    on_exit = function(_, code, _)
      if job_id <= 0 then
        callback({ success = false, error = "Failed to start curl process", })
        return
      end

      if code ~= 0 then
        local err = table.concat(stderr_data, "")
        callback({
          success = false,
          error = "curl exited with code "
            .. (code or "unknown")
            .. (err ~= "" and ": " .. err or ""),
        })
        return
      end

      local output = table.concat(stdout_data, "")
      if not output or vim.trim(output) == "" then
        callback({ success = false, error = "Provider returned empty response", })
        return
      end

      local ok, decoded = pcall(vim.json.decode, output)
      if not ok then
        callback({ success = false, error = "Could not parse API response: " .. output, })
        return
      end

      local content = extract_content(decoded, is_anthropic)
      if type(content) ~= "string" or content == "" then
        callback({ success = false, error = "Provider returned empty content", })
        return
      end

      callback({ success = true, })
    end,
  })

  if job_id <= 0 then
    callback({ success = false, error = "Failed to start curl process", })
  end
end

return AI
