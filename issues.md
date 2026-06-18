# the plugin should work in 4 different ways:
- `:AskAI` is called in visual mode: it should get the selection from `<` and `>` markers: should
  route the prompts with selection;
- `:AskAI` is called in normal mode (no selection) -> should route to the prompts without selection
- AskAI.ask function is called directly from lua (for example, from a keybind) with selected code;
  should get the selected code and route to the prompt with selection;
- AskAI.ask function is called from lua (for example, from a keybind) without selected code; should get
  the selected code and route to the prompt with no selection.

# issues
- sometimes after asking a prompt with selection and then asking a prompt without the selection the
  second prompt thinks the previous selection is still active;
- sometimes calling `:AskAI` in normal behaves as if the first line of the file is selected.

# improvements
- prompts should be as simple and clear as possible;
- some code in askai.lua should be moved to utils.lua. readability is a core goal; a user should be
  able to read it and understand it without needing to understand the details of logic of each part,
  just the overall orchestration of the parts;
- code style and quality should match my other plugins installed on the system: learning.nvim and
  doing.nvim with doing.nvim being the ground truth for code style, quality and structure.

# proposed solution
do a deep research on the neovim documention and reddit questions about similar issues with
reliability of detecting selection and a massive rewrite of the get selection logic and checking if
code is actually selected. also search other plugins that integrate AI with nvim and see if they do
something similar.
reliability, simplicity and readability should be the core goals of the codebase.
