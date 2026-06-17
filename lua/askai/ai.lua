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

---@param prompt string
---@return table, string, boolean
local function build_request(prompt)
  local is_anthropic = config.options.provider.api_url:find("anthropic.com", 1, true)

  local headers = { ["Content-Type"] = "application/json", }
  local body

  if is_anthropic then
    headers["x-api-key"] = config.options.provider.api_key
    headers["anthropic-version"] = "2023-06-01"
    body = vim.json.encode({
      model = config.options.provider.model,
      max_tokens = 4096,
      messages = { { role = "user", content = prompt, }, },
    })
  else
    headers["Authorization"] = "Bearer " .. config.options.provider.api_key
    body = vim.json.encode({
      model = config.options.provider.model,
      messages = { { role = "user", content = prompt, }, },
    })
  end

  ---@diagnostic disable-next-line: return-type-mismatch
  return headers, body, is_anthropic
end

-- Raw API request ------------------------------------------------------------

--- Make an AI request and parse the structured JSON response.
---@param prompt string
---@param callback fun(response: table|nil)
function AI.ask(prompt, callback)
  local headers, body, is_anthropic = build_request(prompt)

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
        if cok and type(parsed) == "table"
            and (type(parsed.summary) == "string" and parsed.summary ~= ""
              or parsed.type == "informational" or parsed.type == "action") then
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

-- High-level prompt builders -------------------------------------------------

--- Classify the user's question as "action" or "informational".
---@param question string
---@param callback fun(result: { type: "action"|"informational" }|nil)
function AI.classify(question, callback)
  local prompt = [[
Question: ]] .. question .. [[

Classify as "action" if the user wants any code edit (add, change, fix,
refactor, modify, update, remove, rewrite, convert, optimize, simplify, etc.).
Classify as "informational" only if the user just wants an explanation or
question answered without changing the code.

Examples:
- "explain this"              -> informational
- "what does this do"         -> informational
- "add logging"               -> action
- "fix the bug"               -> action
- "add emojis to this line"   -> action
- "refactor this function"    -> action

Return only: {"type": "informational"} or {"type": "action"}
]]

  AI.ask(prompt, function(resp)
    if not resp or not resp.type
        or not (resp.type == "action" or resp.type == "informational") then
      vim.notify("[askai.nvim] could not determine request type",
        vim.log.levels.WARN)
      callback(nil)
      return
    end
    callback(resp)
  end)
end

--- Ask the AI to edit the selected text.
---@param question string
---@param selected_text string
---@param sel_start_line integer
---@param full_file string
---@param filetype string
---@param callback fun(response: table|nil)
function AI.action(question, selected_text, sel_start_line, full_file, filetype,
    callback)
  local prompt = [[
{
  "question": "]] .. question .. [["
  "selected_text": "]] .. selected_text .. [["
  "selection_start_line": ]] .. sel_start_line .. [[
  "full_file": "]] .. full_file .. [["
  "filetype": "]] .. filetype .. [["
}

The "edit" replaces lines in the full file. `start` is fixed to
`selection_start_line` (the selection's first line). Only provide `content`
(the replacement lines) and optionally `final` (0-indexed exclusive end line;
defaults to `start + #content`).

Return:
{
  "summary": "brief description + annotated code block showing the result",
  "edit": {
    "content": ["line 1", "line 2", ...]
  }
}

Example for a single-line selection at line 2 asking to add emojis:
{
  "summary": "Will add the 👋 emoji.\n```lua\n  print('👋 hello 👋')```",
  "edit": {
    "content": [" print('👋 hello 👋')"]
  }
}
]]

  AI.ask(prompt, function(resp)
    if resp and resp.summary then
      if not resp.edit or type(resp.edit) ~= "table" or not resp.edit.content then
        local code_block = resp.summary:match("```[^\n]*\n(.-)\n```")
        if code_block then
          resp.edit = {
            content = vim.split(code_block, "\n", { plain = true, }),
          }
        else
          vim.notify(
            "[askai.nvim] AI response missing edit and no code block found",
            vim.log.levels.ERROR)
          callback(nil)
          return
        end
      end
      -- Pin start to the selection's file line
      if selected_text ~= "" then
        resp.edit.start = sel_start_line
        if not resp.edit.final then
          resp.edit.final = sel_start_line + #resp.edit.content
        end
      end
    end
    callback(resp)
  end)
end

--- Ask an informational question about the selected text.
---@param question string
---@param selected_text string
---@param full_file string
---@param filetype string
---@param callback fun(response: table|nil)
function AI.informational(question, selected_text, full_file, filetype, callback)
  local prompt = [[
{
  "question": "]] .. question .. [["
  "selected_text": "]] .. selected_text .. [["
  "full_file": "]] .. full_file .. [["
  "filetype": "]] .. filetype .. [["
}

Return a JSON object like this:
{
  "summary": answer in markdown to the `question` about the `selected_text` in
    context to the `full_file`. any fenced code blocks must be annotated with
    the `filetype`.
}
]]

  AI.ask(prompt, callback)
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
