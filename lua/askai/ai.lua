local config = require("askai.config")

local AI = {}

---@param body table decoded API response body
---@param is_anthropic boolean whether the provider is Anthropic
---@return string|nil the text content from the response
local function extract_content(body, is_anthropic)
  if is_anthropic then
    return body.content and body.content[1] and body.content[1].text
  else
    return body.choices and body.choices[1] and body.choices[1].message.content
  end
end

---@param prompt string the prompt to send
---@return table headers, string body, boolean is_anthropic
local function build_request(prompt)
  local is_anthropic = config.options.provider.api_url:find("anthropic.com", 1, true)

  local headers = { ["Content-Type"] = "application/json" }
  local body

  if is_anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"
    body = vim.json.encode({
      model = config.options.provider.model,
      max_tokens = 4096,
      messages = { { role = "user", content = prompt } },
    })
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key
    body = vim.json.encode({
      model = config.options.provider.model,
      messages = { { role = "user", content = prompt } },
    })
  end

---@diagnostic disable-next-line: return-type-mismatch
  return headers, body, is_anthropic
end

--- Makes an AI request and parses the structured JSON response.
--- Falls back to wrapping the raw text in a { summary = ... } if JSON parsing fails.
---@param prompt string the prompt to send
---@param callback fun(response: { summary: string, edit?: { start: integer, final: integer, content: string[] } })
function AI.ask(prompt, callback)
  local headers, body, is_anthropic = build_request(prompt)

  local cmd = { "curl", "-sS", "-X", "POST", config.options.provider.api_url }
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

        -- Empty output means curl couldn't reach the API or got no response
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
          callback({ summary = "Could not parse API response:\n```\n" .. output .. "\n```" })
          return
        end

        local content = extract_content(decoded, is_anthropic)
        if type(content) ~= "string" or content == "" then
          callback({
            summary = "The AI returned an empty response "
              .. "(`choices` field not found or empty).\n\n"
              .. "Raw API response:\n```json\n" .. output .. "\n```",
          })
          return
        end

        -- Try to parse the content as structured JSON
        local cok, parsed = pcall(vim.json.decode, content)
        if not cok then
          -- Strip markdown fenced code block if the AI wrapped JSON in ```json
          local stripped = content:match("^```[Jj][Ss][Oo][Nn]?\n(.-)\n```$")
          if stripped then
            cok, parsed = pcall(vim.json.decode, stripped)
          end
        end
        if cok and type(parsed) == "table" and (type(parsed.summary) == "string" and parsed.summary ~= "" or parsed.type == "informational" or parsed.type == "action") then
          callback(parsed)
        else
          callback({ summary = content })
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
          callback({ summary = "Request error:\n```\n" .. err .. "\n```" })
        else
          callback({ summary = "No response from AI." })
        end
      end)
    end,
  })
end

--- Make a synchronous test request to validate provider config.
--- Returns { success = boolean, error = string? }
function AI.validate_provider()
  local test_prompt = "Reply with exactly: OK"
  local headers, body, is_anthropic = build_request(test_prompt)

  local cmd = { "curl", "-sS", "-X", "POST", config.options.provider.api_url }
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
    return { success = false, error = "Failed to start curl process" }
  end

  local result = vim.fn.jobwait({ job_id }, 15000) -- 15s timeout
  if not result or result[1] ~= 0 then
    local err = table.concat(stderr_data, "")
    return { success = false, error = "curl exited with code " .. (exit_code or (result and result[1] or "unknown")) .. (err ~= "" and ": " .. err or "") }
  end

  local output = table.concat(stdout_data, "")
  if not output or vim.trim(output) == "" then
    return { success = false, error = "Provider returned empty response" }
  end

  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then
    return { success = false, error = "Could not parse API response: " .. output }
  end

  local content = extract_content(decoded, is_anthropic)
  if type(content) ~= "string" or content == "" then
    return { success = false, error = "Provider returned empty content" }
  end

  return { success = true }
end

return AI
