-- askai.nvim - Ask AI about your code
-- commands:
--   :AskAI {question}     Ask with a question
--   :AskAI                Prompts for a question via input()

local askai = require("askai")

-- sets up the :AskAI command
vim.api.nvim_create_user_command("AskAI", function(args)
  local question = args.args
  if question == "" then
    -- prompt for a question when not provided
    question = vim.fn.input("Ask AI: ")
    if question == "" then
      return
    end
  end
  askai.ask(question)
end, {
  range = true,
  nargs = "*",
  desc = "Ask AI about the current document and visual selection",
})
