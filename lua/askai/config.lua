local Config = {}

local HEIGHT = 50
local WIDTH = 120

---@class askai.Config
---@field provider askai.Config.Provider provider options for the AI
---@field keys? askai.Config.Keys keymaps for the suggestion window
---@field win_config? table window config for the suggestion window (see :h nvim_open_win())
---@field spinner_characters? string[] characters for the loading spinner animation
---@field spinner_interval_ms? number interval in ms between spinner frames
---@field highlights? table highlight group definitions (table of args or link string)
Config.options = {
  ---@class askai.Config.Provider
  ---@field api_key string API key for the provider
  ---@field api_url string API URL for the provider
  ---@field model string model to use for the provider
  ---@field headers? table<string, string> DEV ONLY: extra request headers; an empty value removes a header
  provider = { api_key = "", api_url = "", model = "", },

  ---@class askai.Config.Keys
  ---@field confirm? string keymap to accept the suggested edit
  ---@field dismiss? string keymap to dismiss the floating window
  keys = { confirm = "<S-CR>", dismiss = "<Esc>", },

  spinner_characters = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷", },
  spinner_interval_ms = 80,

  ---@class askai.Config.Highlights
  ---@field AskaiNormal? table|string highlight for the floating window background/text
  ---@field AskaiBorder? table|string highlight for the floating window border
  ---@field AskaiWinbar? table|string highlight for the winbar text
  ---@field AskaiSpinner? table|string highlight for the loading spinner
  highlights = {
    AskaiNormal = { link = "NormalFloat", },
    AskaiBorder = { fg = "#89b4fa", },
    AskaiWinbar = { link = "WinBar", },
    AskaiSpinner = { fg = "#89b4fa", bold = true, },
    AskaiDiffAdd = { link = "DiffAdd", },
    AskaiDiffDelete = { link = "DiffDelete", },
  },

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
