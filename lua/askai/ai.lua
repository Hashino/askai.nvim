local config = require("askai.config")

---@class askai.AI [Hashino/askai.nvim] AI provider requests
local AI = {}

--- true when the configured provider is Anthropic (different request shape)
---@return boolean
local function is_anthropic()
  return config.options.provider.api_url:find("anthropic.com", 1, true) ~= nil
end

--- extracts the assistant text from a decoded response
---@param body table
---@param anthropic boolean
---@return string|nil
local function extract_content(body, anthropic)
  if anthropic then
    for _, block in ipairs(body.content or {}) do
      if block.type == "text" then return block.text end
    end
    return nil
  end

  local msg = body.choices and body.choices[1] and body.choices[1].message
  if msg then
    -- some reasoning models reply with `reasoning` and an empty `content`
    if type(msg.content) == "string" then return msg.content end
    if type(msg.reasoning) == "string" then return msg.reasoning end
  end
  return nil
end

--- extracts a human-readable error message from an error response.
--- handles `{ error = "msg", message = "..." }` (Mercury) and
--- `{ error = { message = "..." } }` (OpenAI/Anthropic)
---@param decoded table
---@return string|nil
local function extract_error(decoded)
  local err = decoded.error
  if type(err) == "string" then
    if type(decoded.message) == "string" and decoded.message ~= "" then
      return err .. ": " .. decoded.message
    end
    return err
  elseif type(err) == "table" then
    return err.message or err.type or vim.json.encode(err)
  end
  return nil
end

--- extracts every tool call from a decoded response
---@param decoded table
---@param anthropic boolean
---@return { name: string, arguments: table }[]
local function extract_tool_calls(decoded, anthropic)
  local calls = {}
  if anthropic then
    for _, block in ipairs(decoded.content or {}) do
      if block.type == "tool_use" then
        table.insert(calls, { name = block.name, arguments = block.input, })
      end
    end
  else
    local msg = decoded.choices and decoded.choices[1] and decoded.choices[1].message
    for _, call in ipairs(msg and msg.tool_calls or {}) do
      if call.type == "function" and call["function"] then
        local ok, args = pcall(vim.json.decode, call["function"].arguments)
        if ok then
          table.insert(calls, { name = call["function"].name, arguments = args, })
        end
      end
    end
  end
  return calls
end

--- builds a tool definition in the active provider's format.
--- every property is treated as required.
---@param anthropic boolean
---@param name string
---@param description string
---@param properties table<string, table>
---@return table
local function make_tool(anthropic, name, description, properties)
  local schema = {
    type = "object",
    properties = properties,
    required = vim.tbl_keys(properties),
  }

  if anthropic then
    return { name = name, description = description, input_schema = schema, }
  end

  return {
    type = "function",
    ["function"] = { name = name, description = description, parameters = schema, },
  }
end

--- builds the request headers and body. optionally includes tool definitions.
---@param prompt string
---@param tools? table[]
---@return table headers, string body, boolean anthropic
local function build_request(prompt, tools)
  local anthropic = is_anthropic()

  local headers = { ["Content-Type"] = "application/json", }
  local payload = {
    model = config.options.provider.model,
    messages = { { role = "user", content = prompt, }, },
  }

  if anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"
    payload.max_tokens = 4096
    if tools then
      payload.tools = tools
      payload.tool_choice = { type = "auto", }
    end
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key
    if tools then
      payload.tools = tools
      payload.tool_choice = "auto"
    end
  end

  -- DEVELOPMENT ONLY: merge user-supplied headers over the defaults so the test
  -- harness can reach keyless dev endpoints (an empty-string value removes a
  -- header, e.g. blanking Authorization). Not a supported production feature.
  for k, v in pairs(config.options.provider.headers or {}) do
    headers[k] = (v ~= "" and v) or nil
  end

  return headers, vim.json.encode(payload), anthropic
end

--- POSTs `prompt` to the provider and calls `callback` once the request finishes.
--- Neovim has no built-in HTTP client that can POST with headers and a body
--- (`vim.net.request` is GET only), so we shell out to curl through the native
--- `vim.system`. Its callback runs in a fast context, hence `schedule_wrap`.
---@param prompt string
---@param tools? table[]
---@param callback fun(res: { ok: boolean, decoded?: table, output: string, stderr: string, code: integer, anthropic: boolean })
local function request(prompt, tools, callback)
  local headers, body, anthropic = build_request(prompt, tools)

  local cmd = { "curl", "-sS", "-X", "POST", config.options.provider.api_url, }
  for k, v in pairs(headers) do
    vim.list_extend(cmd, { "-H", k .. ": " .. v, })
  end
  vim.list_extend(cmd, { "-d", body, })

  local ok, err = pcall(vim.system, cmd, { text = true, }, vim.schedule_wrap(function(out)
    local decoded_ok, decoded = pcall(vim.json.decode, out.stdout or "")
    callback({
      ok = decoded_ok,
      decoded = decoded_ok and decoded or nil,
      output = out.stdout or "",
      stderr = vim.trim(out.stderr or ""),
      code = out.code,
      anthropic = anthropic,
    })
  end))

  if not ok then
    callback({ ok = false, output = "", stderr = tostring(err), code = -1, anthropic = anthropic, })
  end
end

--- classifies user intent as "action" or "informational"
---@param question string
---@param callback fun(intent: "action"|"informational")
function AI.classify(question, callback)
  local prompt = [[Classify the request below. Reply with exactly one word:

- "action": the user wants to change the code (add, fix, refactor, remove, rename...).
- "informational": the user wants to understand the code or get an answer (explain, how, why, what...).

Examples:
fix the bug on line 10 -> action
refactor this function -> action
remove the unused variable -> action
explain this function -> informational
what does this file do? -> informational
why is this slow? -> informational

Request: ]] .. question

  -- default to "action" (the safe, reversible path) unless the model clearly
  -- says "informational"; it may add punctuation, casing, or reasoning text
  request(prompt, nil, function(res)
    local content = res.decoded and extract_content(res.decoded, res.anthropic)
    if type(content) == "string" and content:lower():find("informational", 1, true) then
      callback("informational")
    else
      callback("action")
    end
  end)
end

--- makes an AI request, returning tool calls or a `{ summary }` table
---@param prompt string
---@param callback fun(response: { name: string, arguments: table }[]|table|nil)
---@param tools? table[]
function AI.ask(prompt, callback, tools)
  request(prompt, tools, function(res)
    if not res.ok then
      if res.stderr ~= "" then
        callback({ summary = "Request error:\n```\n" .. res.stderr .. "\n```", })
      elseif vim.trim(res.output) == "" then
        callback({ summary = "The AI provider returned an empty response.\n\n"
          .. "Check that your **api_url** is correct and your network can reach it.\n\n"
          .. "Current url: `" .. config.options.provider.api_url .. "`", })
      else
        callback({ summary = "Could not parse API response:\n```\n" .. res.output .. "\n```", })
      end
      return
    end

    -- surface API errors (bad key, server error, ...) in a readable way
    local api_err = extract_error(res.decoded)
    if api_err then
      callback({ summary = "The AI provider returned an error:\n\n" .. api_err, })
      return
    end

    local tool_calls = extract_tool_calls(res.decoded, res.anthropic)
    if #tool_calls > 0 then
      callback(tool_calls)
      return
    end

    -- content-only fallback (no tool call returned)
    local content = extract_content(res.decoded, res.anthropic)
    if type(content) == "string" and content ~= "" then
      callback({ summary = content, })
    else
      callback({ summary = "The AI returned an empty response.\n\n"
        .. "Raw API response:\n```json\n" .. res.output .. "\n```", })
    end
  end)
end

--- action: prompt + edit tools only
---@param context { question: string, selected_text?: string, full_file: string, filetype: string }
---@param callback fun(response: table|nil)
function AI.ask_action(context, callback)
  local ft = context.filetype or ""

  local prompt
  if context.selected_text and context.selected_text ~= "" then
    prompt = "Edit only the selected code to satisfy this request: " .. context.question .. "\n\n"
      .. "Selection (edit ONLY this):\n```" .. ft .. "\n" .. context.selected_text .. "\n```\n\n"
      .. "Full file (context only, do NOT edit outside the selection):\n"
      .. "```" .. ft .. "\n" .. context.full_file .. "\n```"
  else
    prompt = "Edit the file to satisfy this request: " .. context.question .. "\n\n"
      .. "```" .. ft .. "\n" .. context.full_file .. "\n```"
  end

  prompt = prompt .. "\n\nApply changes with the `edit` tool (replaces the first exact match) or"
    .. "\n`edit_all` (replaces every match). `oldString` must match the file"
    .. "\nexactly, including whitespace and line breaks."

  local props = {
    oldString = {
      type = "string",
      description = "The EXACT text to find in the file. Must match whitespace and line breaks exactly.",
    },
    newString = { type = "string", description = "The replacement text", },
  }
  local anthropic = is_anthropic()
  local tools = {
    make_tool(anthropic, "edit", "Replace exact text; only the FIRST matching occurrence is replaced.", props),
    make_tool(anthropic, "edit_all", "Replace exact text; ALL matching occurrences are replaced.", props),
  }

  AI.ask(prompt, function(resp)
    if type(resp) ~= "table" or not resp[1] then
      callback(resp or nil)
      return
    end

    local edits = {}
    for _, tc in ipairs(resp) do
      if tc.name == "edit" or tc.name == "edit_all" then
        table.insert(edits, {
          oldString = tc.arguments.oldString,
          newString = tc.arguments.newString,
          all = tc.name == "edit_all",
        })
      end
    end
    callback(#edits > 0 and { edits = edits, } or nil)
  end, tools)
end

--- informational: prompt + explain tool only
---@param context { question: string, selected_text?: string, full_file: string, filetype: string }
---@param callback fun(response: table|nil)
function AI.ask_explain(context, callback)
  local ft = context.filetype or ""

  local prompt
  if context.selected_text and context.selected_text ~= "" then
    prompt = "Answer this question about the selected code: " .. context.question .. "\n\n"
      .. "Selection (focus on this):\n```" .. ft .. "\n" .. context.selected_text .. "\n```\n\n"
      .. "Full file (context only):\n```" .. ft .. "\n" .. context.full_file .. "\n```"
  else
    prompt = "Answer this question about the file: " .. context.question .. "\n\n"
      .. "```" .. ft .. "\n" .. context.full_file .. "\n```"
  end

  prompt = prompt .. "\n\nAnswer with the `explain` tool. Use Markdown, and put code in"
    .. "\nfenced blocks annotated with the language (e.g. ```" .. (ft ~= "" and ft or "lua") .. ")."

  local tools = {
    make_tool(is_anthropic(), "explain",
      "Explain code or answer a question about it. Use this whenever the user asks a question or wants to understand code.",
      { summary = { type = "string", description = "Markdown explanation answering the user's question", }, }),
  }

  AI.ask(prompt, function(resp)
    if type(resp) ~= "table" or not resp[1] then
      callback(resp or nil)
      return
    end

    local parts = {}
    for _, tc in ipairs(resp) do
      if tc.name == "explain" then table.insert(parts, tc.arguments.summary) end
    end
    callback(#parts > 0 and { summary = table.concat(parts, "\n\n---\n\n"), } or nil)
  end, tools)
end

--- makes a test request to validate the provider config
---@param callback fun(result: { success: boolean, error?: string })
function AI.validate_provider(callback)
  request("Reply with exactly: OK", nil, function(res)
    if res.code ~= 0 then
      callback({ success = false,
        error = "curl exited with code " .. res.code .. (res.stderr ~= "" and ": " .. res.stderr or ""), })
    elseif vim.trim(res.output) == "" then
      callback({ success = false, error = "provider returned empty response", })
    elseif not res.ok then
      callback({ success = false, error = "could not parse API response: " .. res.output, })
    elseif extract_error(res.decoded) then
      callback({ success = false, error = extract_error(res.decoded), })
    elseif type(extract_content(res.decoded, res.anthropic)) ~= "string" then
      callback({ success = false, error = "provider returned empty content", })
    else
      callback({ success = true, })
    end
  end)
end

return AI
