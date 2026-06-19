<div align="right">
  <a href="https://www.buymeacoffee.com/Hashino" target="_blank">
    <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png"
    alt="Buy Me A Coffee" style="height: 24px !important;width: 104px !important;" >
</div>

# askai.nvim

<a href="https://dotfyle.com/plugins/Hashino/askai.nvim">
	<img src="https://dotfyle.com/plugins/Hashino/askai.nvim/shield?style=flat" />
</a>

this plugin add the ability to ask your AI something about your code or to do an edit on it. nothing more

![demo1](https://raw.githubusercontent.com/Hashino/askai.nvim/main/demo1.gif)

![demo2](https://raw.githubusercontent.com/Hashino/askai.nvim/main/demo2.gif)

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
end, { desc = "[A]sk [A]I about selection" })
```

## usage

**With text selected** (visual mode):
```
:'<,'>AskAI why is this function slow?
```

**Without selection** (normal mode):
```
:AskAI what does this file do?
```

The AI receives:

- your **question**
- the **selected text** (if any)
- the **full document** for context

When no text is selected, the AI answers questions about the entire file. When text is selected, it focuses on that region while using the full file as context.

A braille spinner (`⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷`) animates in the bottom-right corner while waiting for the response. The answer appears in a floating window with `syntax=markdown`. If the AI suggests a code edit, press `<S-CR>` (configurable) to apply it, or `<Esc>` to dismiss.

## provider requirements

Your AI provider must support **tool calling** (also called function calling).
Compatible providers include:

- OpenAI / OpenAI-compatible APIs (OpenAI, Together, Groq, etc.)
- Anthropic (Claude)

Providers without tool calling support will **not** work with this plugin.

## config

[see the source code for default options](https://github.com/Hashino/askai.nvim/blob/main/lua/askai/config.lua)

## testing

The `tests/` directory provides a manual test suite for your coding agent to run
if you want to fork or contribute to the plugin. It drives a real Neovim session
with [tui-use](https://github.com/onesuper/tui-use) and ships a keyless config
(`tests/init.lua`) that uses a free provider, so no API key is needed.

See [`tests/tests.md`](https://github.com/Hashino/askai.nvim/blob/main/tests/tests.md)
for the plan and how to run it.
