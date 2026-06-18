-- askai.nvim - Ask AI about your code
-- commands:
--   :AskAI {question}     Ask with a question
--   :AskAI                Prompts for a question via input()

local askai = require("askai")

vim.api.nvim_create_user_command("AskAI", function(args)
  -- args.range is 2 only when an explicit range was given (e.g. :'<,'>AskAI).
  -- in that case the selection is exactly the lines line1..line2. a plain
  -- :AskAI from normal mode has range == 0, so it carries no selection.
  local selection
  if args.range == 2 then
    local lines = vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false)
    selection = table.concat(lines, "\n")
  end

  askai.ask(args.args, selection)
end, {
  range = true,
  nargs = "*",
  desc = "Ask AI about the current document and visual selection",
  complete = function(_, cmd_line)
    if #vim.split(cmd_line, "%s+", { trimempty = true, }) <= 1 then
      return {}
    end
  end,
})
