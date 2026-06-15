<div align="right">
  <a href="https://www.buymeacoffee.com/Hashino" target="_blank">
    <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png"
    alt="Buy Me A Coffee" style="height: 24px !important;width: 104px !important;" >
  </a>
</div>

# askai.nvim

ask your AI about your code

![demo](https://raw.githubusercontent.com/Hashino/askai.nvim/main/demo.gif)

## commands

- `:AskAI {question}` asks the AI with the provided question, including the current visual selection (if any) and the full document as context
- `:AskAI` prompts for a question via input

The command works from visual mode (`:'<,'>AskAI why is this wrong?`) or from normal mode (`:AskAI what does this file do?`).

## installation

lazy.nvim:
```lua
{
  "Hashino/askai.nvim",
  opts = {
    provider = {
      api_key = "", -- your API key. be careful putting it in your dotfiles
      api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
      model = "", -- the model you want to use, should be specified in the docs of your provider
    },
  },
}
```

vim.pack:
```lua
vim.pack.add({ "https://github.com/Hashino/askai.nvim", })
require("askai").setup({
  provider = {
    api_key = "", -- your API key. be careful putting it in your dotfiles
    api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
    model = "", -- the model you want to use, should be specified in the docs of your provider
  },
})
```

## keymap example

```lua
vim.keymap.set("v", "<leader>aa", function()
  require("askai").ask("explain this code")
end, { desc = "Ask AI about selection" })
```

## usage

Select some text in visual mode, then:

```
:'<,'>AskAI why is this function slow?
```

The AI receives:

- your **question**
- the **selected text** (if any)
- the **full document** for context

A braille spinner (`⣾⣽⣻⢿⡿⣟⣯⣷`) animates in the bottom-right corner while waiting for the response. The answer appears in a floating window with `syntax=markdown`. If the AI suggests a code edit, press `<S-CR>` (configurable) to apply it, or `<Esc>` to dismiss.

## config

[see the source code for default options](https://github.com/Hashino/askai.nvim/blob/main/lua/askai/config.lua)
