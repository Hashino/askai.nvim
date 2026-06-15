-- askai.nvim - Ask AI about your code
-- commands:
--   :AskAI {question}     Ask with a question
--   :AskAI                Prompts for a question via input()

local askai = require("askai")

vim.api.nvim_create_user_command("AskAI", function(args)
  askai.ask(args.args)
end, {
  range = true,
  nargs = "*",
  desc = "Ask AI about the current document and visual selection",
  complete = function(_, cmd_line)
    if #vim.split(cmd_line, "%s+", { trimempty = true }) <= 1 then
      return {}
    end
  end,
})