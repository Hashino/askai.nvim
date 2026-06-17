local config = require("askai.config")

---@class askai.AI [Hashino/askai.nvim] AI provider requests

local AI = {}

-- Low-level helpers ----------------------------------------------------------

---@param body table
---@param is_anthropic boolean
---@return string|nil
local function extract_content(body, is_anthropic)
  if is_anthropic then
    return body.content and body.content[1] and body.content[1].text
  else
    return body.choices and body.choices[1] and body.choices[1].message.content
  end
end

--- Extract a tool call from the API response.
---@param decoded table
---@param is_anthropic boolean
---@return { name: string, arguments: table }|nil
local function extract_tool_call(decoded, is_anthropic)
  if is_anthropic then
    if decoded.content then
      for _, block in ipairs(decoded.content) do
        if block.type == "tool_use" then
          return { name = block.name, arguments = block.input, }
        end
      end
    end
  else
    local msg = decoded.choices and decoded.choices[1] and decoded.choices[1].message
    if msg and msg.tool_calls then
      local call = msg.tool_calls[1]
      if call and call.type == "function" and call["function"] then
        local ok, args = pcall(vim.json.decode, call["function"].arguments)
        if ok then
          return { name = call["function"].name, arguments = args, }
        end
      end
    end
  end
  return nil
end

--- Build HTTP request headers and body. Optionally includes tool definitions.
---@param prompt string
---@param tools? table[]
---@return table, string, boolean
local function build_request(prompt, tools)
  local is_anthropic = config.options.provider.api_url:find("anthropic.com", 1, true)

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

  ---@diagnostic disable-next-line: return-type-mismatch
  return headers, body, is_anthropic
end

--- Build the `askai_edit` tool definition in the provider's format.
---@param is_anthropic boolean
---@return table
local function build_edit_tool(is_anthropic)
  local schema = {
    type = "object",
    properties = {
      summary = {
        type = "string",
        description = "Brief markdown summary of the edit with a code block showing the result",
      },
      start = {
        type = "integer",
        description = "0-indexed start line of the edit in the file",
      },
      ["final"] = {
        type = "integer",
        description = "0-indexed exclusive end line of the edit",
      },
      content = {
        type = "array",
        items = { type = "string", },
        description = "Replacement lines for the edit",
      },
    },
    required = { "summary", "start", "final", "content", },
  }

  if is_anthropic then
    return {
      name = "askai_edit",
      description = "Edit code lines in the file. Call this when the user asks to change, fix, refactor, add, or modify code.",
      input_schema = schema,
    }
  end

  return {
    type = "function",
    ["function"] = {
      name = "askai_edit",
      description = "Edit code lines in the file. Call this when the user asks to change, fix, refactor, add, or modify code.",
      parameters = schema,
    },
  }
end

--- Build the `askai_explain` tool definition in the provider's format.
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
      name = "askai_explain",
      description = "Explain code or answer a question. Call this when the user asks a question, wants an explanation, or wants to understand code.",
      input_schema = schema,
    }
  end

  return {
    type = "function",
    ["function"] = {
      name = "askai_explain",
      description = "Explain code or answer a question. Call this when the user asks a question, wants an explanation, or wants to understand code.",
      parameters = schema,
    },
  }
end

-- Raw API request ------------------------------------------------------------

--- Make an AI request. When `tools` is provided, extract the first tool call
--- and call callback with `{ name, arguments }`. Otherwise fall back to
--- parsing JSON from the response text (legacy behaviour).
---@param prompt string
---@param callback fun(response: table|nil)
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
        if tools then
          local tool_call = extract_tool_call(decoded, is_anthropic)
          if tool_call then
            callback(tool_call)
            return
          end
        end

        -- Legacy content parsing path
        local content = extract_content(decoded, is_anthropic)
        if type(content) ~= "string" or content == "" then
          callback({
            summary = "The AI returned an empty response "
              .. "(`choices` field not found or empty).\n\n"
              .. "Raw API response:\n```json\n" .. output .. "\n```",
          })
          return
        end

        local cok, parsed = pcall(vim.json.decode, content)
        if not cok then
          local stripped = content:match("^```[Jj][Ss][Oo][Nn]?\n(.-)\n```$")
          if stripped then
            cok, parsed = pcall(vim.json.decode, stripped)
          end
        end
        if cok and type(parsed) == "table" then
          callback(parsed)
        else
          callback({ summary = content, })
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

-- High-level tool-calling entry point ----------------------------------------

--- Send user context with tool definitions and return the chosen tool call.
---@param context { question: string, selected_text?: string, sel_start_line?: integer, full_file: string, filetype: string }
---@param callback fun(response: table|nil)
function AI.ask_with_tools(context, callback)
  local is_anthropic = config.options.provider.api_url:find("anthropic.com", 1, true)

  local tools = {
    build_edit_tool(is_anthropic),
    build_explain_tool(is_anthropic),
  }

  local prompt_parts = {}
  table.insert(prompt_parts, "Question: " .. context.question)
  table.insert(prompt_parts, "")
  table.insert(prompt_parts, "Full file:")
  table.insert(prompt_parts, "```" .. (context.filetype or "") .. "")
  table.insert(prompt_parts, context.full_file)
  table.insert(prompt_parts, "```")

  if context.selected_text and context.selected_text ~= "" then
    table.insert(prompt_parts, "")
    table.insert(prompt_parts, "Selected text:")
    table.insert(prompt_parts, "```")
    table.insert(prompt_parts, context.selected_text)
    table.insert(prompt_parts, "```")
  end

  local prompt = table.concat(prompt_parts, "\n")

  AI.ask(prompt, function(resp)
    if not resp then
      callback(nil)
      return
    end

    if resp.name then
      local args = resp.arguments
      if resp.name == "askai_edit" then
        local result = {
          summary = args.summary,
          edit = {
            start = args.start,
            final = args["final"],
            content = args.content,
          },
        }
        if context.sel_start_line
            and context.selected_text and context.selected_text ~= "" then
          result.edit.start = context.sel_start_line
          if not result.edit.final then
            result.edit.final = context.sel_start_line + #result.edit.content
          end
        end
        callback(result)
      elseif resp.name == "askai_explain" then
        callback({ summary = args.summary, })
      else
        callback(nil)
      end
    else
      -- Fallback: content response (error or raw text)
      callback(resp)
    end
  end, tools)
end

-- Validation -----------------------------------------------------------------

--- Make a synchronous test request to validate provider config.
---@return { success: boolean, error?: string }
function AI.validate_provider()
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
  local exit_code = nil

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
      exit_code = code
    end,
  })

  if job_id <= 0 then
    return { success = false, error = "Failed to start curl process", }
  end

  local result = vim.fn.jobwait({ job_id, }, 15000)
  if not result or result[1] ~= 0 then
    local err = table.concat(stderr_data, "")
    return {
      success = false,
      error = "curl exited with code "
        .. (exit_code or (result and result[1] or "unknown"))
        .. (err ~= "" and ": " .. err or ""),
    }
  end

  local output = table.concat(stdout_data, "")
  if not output or vim.trim(output) == "" then
    return { success = false, error = "Provider returned empty response", }
  end

  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then
    return { success = false, error = "Could not parse API response: " .. output, }
  end

  local content = extract_content(decoded, is_anthropic)
  if type(content) ~= "string" or content == "" then
    return { success = false, error = "Provider returned empty content", }
  end

  return { success = true, }
end

return AI
