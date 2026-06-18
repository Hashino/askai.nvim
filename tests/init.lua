-- DEVELOPMENT ONLY — keyless Neovim config for running the askai.nvim test plan
-- (see tests/tests.md). It points at OpenCode Zen's free models, which are reached
-- with no Authorization header. `provider.headers` blanking Authorization is a
-- development-only escape hatch; do not use this pattern in real configs.

vim.opt.number = true
vim.opt.relativenumber = false

vim.opt.rtp:append("/home/hashino/.local/share/nvim/site/pack/core/opt/askai.nvim")

require("askai").setup({
  provider = {
    api_url = "https://opencode.ai/zen/v1/chat/completions",
    api_key = "dummy",                 -- free Zen models; only needs to be non-empty
    model   = "nemotron-3-ultra-free", -- free; supports tool calling
    headers = { Authorization = "", }, -- DEV ONLY: Zen free tier wants no auth header
  },
  keys = { confirm = "<C-a>", },       -- PTY-sendable confirm key (see tests.md)
})

vim.keymap.set({ "n", "v", }, "<leader>ai", function()
  require("askai").ask()
end, { desc = "[A]sk A[I]", })
