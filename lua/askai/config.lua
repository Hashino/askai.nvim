local Config = {}

local HEIGHT = 25
local WIDTH = 75

---@class askai.Config
---@field provider askai.Config.Provider provider options for the ai
---@field keys? askai.Config.Keys keymaps for the suggestion window
---@field win_config? table window config for the suggestion window (see :h nvim_open_win())
---@field spinner_characters? string[] characters for the loading spinner animation
---@field spinner_interval_ms? number interval in ms between spinner frames
Config.options = {
  ---@class askai.Config.Provider
  ---@field api_key string api key for the provider
  ---@field api_url string api url for the provider
  ---@field model string model to use for the provider
  provider = { api_key = "", api_url = "", model = "" },

  ---@class askai.Config.Keys
  ---@field confirm string keymap to accept the suggested edit
  ---@field dismiss string keymap to dismiss the floating window
  keys = { confirm = "<S-CR>", dismiss = "<Esc>" },

  spinner_characters = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
  spinner_interval_ms = 80,

  ---@class askai.Config.Highlights
  ---@field AskaiNormal? table|string highlight for the floating window background/text (table of args or link string)
  ---@field AskaiBorder? table|string highlight for the floating window border
  ---@field AskaiWinbar? table|string highlight for the winbar text
  ---@field AskaiSpinner? table|string highlight for the loading spinner
  highlights = {
    AskaiNormal = { link = "NormalFloat" },
    AskaiBorder = { fg = "#89b4fa" },
    AskaiWinbar = { link = "WinBar" },
    AskaiSpinner = { fg = "#89b4fa", bold = true },
  },

  -- Maximum characters of the document to send as context (to avoid hitting token limits)
  max_context_size = 8000,

  -- see :h nvim_open_win() for available options
  win_config = {
    relative = "editor",

    width = WIDTH,
    height = HEIGHT,

    col = vim.o.columns - WIDTH,
    row = vim.o.lines - 3 - vim.o.cmdheight - HEIGHT,

    style = "minimal",
    border = "rounded",

    noautocmd = true,
  },
}

return Config
