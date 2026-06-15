local config = require("askai.config")

local AI = {}

local function extract_content(body, is_anthropic)
  if is_anthropic then
    return body.content and body.content[1] and body.content[1].text
  else
    return body.choices and body.choices[1] and body.choices[1].message.content
  end
end

local function build_request(prompt)
  local is_anthropic = config.options.provider.api_url:find("anthropic%.com")

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

  return headers, body, is_anthropic
end

--- Makes an AI request and parses the structured JSON response.
--- Falls back to wrapping the raw text in a { summary = ... } if JSON parsing fails.
---@param prompt string the prompt to send
---@param callback fun(response: { summary: string, edit?: { start: integer, final: integer, content: string[] } })
function AI.ask(prompt, callback)
  local headers, body, is_anthropic = build_request(prompt)

  local cmd = { "curl", "-s", "-X", "POST", config.options.provider.api_url }
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
        local ok, decoded = pcall(vim.json.decode, output)
        if not ok then
          callback({ summary = tostring(output) })
          return
        end

        local content = extract_content(decoded, is_anthropic)
        if type(content) ~= "string" then
          callback({ summary = "No response from AI." })
          return
        end

        -- Try to parse the content as structured JSON
        local cok, parsed = pcall(vim.json.decode, content)
        if cok and type(parsed) == "table" and parsed.summary then
          callback(parsed)
        elseif content then
          callback({ summary = content })
        else
          callback({ summary = "No response from AI." })
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

return AI
