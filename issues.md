# the plugin should work in 4 different ways:
- `:AskAI` is called in visual mode: it should get the selection from `<` and `>` markers: should
  route the prompts with selection;
- `:AskAI` is called in normal mode (no selection) -> should route to the prompts without selection
- AskAI.ask function is called directly from lua (for example, from a keybind) with selected code;
  should get the selected code and route to the prompt with selection;
- AskAI.ask function is called from lua (for example, from a keybind) without selected code; should
  route to the prompt with no selection.

> [!NOTE]
> revise the 4 prompts: action with selection; action without selection; informational with
> selection; informational without selection;
> each should only provide the appropiate information (only provide selection if there is selection)
> and only the relevant tools (explain tool for informational, edit and edit_all for action)
> make the prompts as concise and clear as possible.

> [!NOTE]
> also revise the classify prompt, it should be as simple and clear as possible

# issues
- sometimes after asking a prompt with selection and after asking another prompt without anything
  selected the second prompt thinks the previous selection is still selected;
- sometimes calling `:AskAI` in normal behaves as if the first line of the file is selected.

# code style and quality
- code style and quality should match my other plugins installed on the system: learning.nvim and
  doing.nvim with doing.nvim being the ground truth for code style, quality and structure.

> [!IMPORTANT]
> reliability, simplicity and readability, in this order, should be the core goals of the codebase.

# proposed solution
do a deep research on the neovim documention and reddit questions about similar issues with
reliability of detecting selection and do a rewrite of the get selection logic and checking if
code is actually selected. also search other plugins that integrate AI with nvim and see if they do
something similar.
