# askai.nvim — manual test plan

Run this whole plan **in a single Neovim session** after any big change to the
selection / routing / prompt logic. Running it in one session is deliberate: the
"stale selection" bug only shows up when a *no-selection* request follows a
*with-selection* one, so every with-selection step is immediately followed by a
no-selection step that must come back clean.

> **How to run it.** This plan is meant to be driven with
> [tui-use](https://github.com/onesuper/tui-use), which automates a real terminal
> so an agent can launch Neovim, send keystrokes, and read the screen back. The
> step keystrokes and the "wait for the response window, then assert" loop map
> directly onto tui-use's `start` / `type` / `press` / `wait` / `snapshot`
> commands. It can also be run by hand — tui-use just makes each run repeatable.

**Generate fresh prompts every run.** Each step names a prompt *category*, not a
sentence. On every run, **invent a new prompt** for each category — do not pick
from a fixed list and do not reuse wording from previous runs. Changing the exact
phrasing each time is what surfaces edge cases a fixed script would miss. The
assertions below are invariants that must hold *regardless* of the wording you
choose, so a freshly written prompt never needs a matching hand-written
expectation.

## Setup

Run the plan with the tracked, keyless dev config — it needs no API key (free
OpenCode Zen models):

```sh
nvim -u tests/init.lua /tmp/complex.lua
```

To run against a different provider, copy `tests/init.lua` and edit the `provider`
block.

`/tmp/complex.lua` (recreate if missing):

```lua
local M = {}

local function log(level, msg)
  print("[" .. level .. "] " .. msg)
end

function M.greet(name)
  log("info", "Starting greeting")
  print("Hello, " .. name)
  print("Welcome aboard")
  return "done"
end

function M.farewell(name)
  log("info", "Saying goodbye")
  print("Goodbye, " .. name)
  print("See you soon")
end

function M.status(ok)
  if ok then
    print("Everything is fine")
  else
    print("Something went wrong")
  end
end

return M
```

Wait until provider validation finishes (no error notification) before starting.

- **Selection target:** the `M.farewell` function, **lines 14–18**.
  Select it with `14G` then `V4j` (VISUAL LINE, 5 lines).
- From visual mode, typing `:` auto-inserts the `'<,'>` range.
- **Outside-selection sentinels:** `log` (lines 3–5), `M.greet` (7–12) and
  `M.status` (20–25) must stay byte-for-byte unchanged after any *with-selection*
  edit.

## Prompt categories (write a new prompt for each, every run)

Don't reuse these descriptions verbatim — they define the *shape* a freshly
generated prompt must have so the invariants still apply. Compose something new
that fits the category each run.

- **INFO** → must request *understanding only*, with no instruction to modify
  code (a question or an "explain/describe…" about the code). Routes to
  `informational`; opens a dismiss-only window.
- **ACTION** → must request *one concrete, localized change* to a single function
  (the selected one, or a named one when no selection). Routes to `action`; opens
  a diff that touches only that function.
- **MULTI** → must request a change that *applies to many occurrences* across the
  file (something repeated: all `print` strings, every string literal, all `log`
  calls, …). Routes to `action`; see "Multi-edit case" below.

Keep each generated prompt unambiguous about scope so the assertions stay
checkable, but otherwise phrase it differently every run.

## How to read results

| Intent          | Window winbar                                   | Content                          |
| --------------- | ----------------------------------------------- | -------------------------------- |
| `informational` | `[AskAI] <Esc> to dismiss`                      | markdown answer                  |
| `action`        | `[AskAI] <S-CR> to accept \| <Esc> to dismiss`  | `-`/`+` diff of the proposed edit |

Dismiss an `informational` window with `<Esc>` before the next step.

### Accepting and verifying action edits

For every `action`/`MULTI` step, apply the diff and confirm the buffer changed:

1. **Accept**: press the confirm key (`<S-CR>` by default, `keys.confirm`).
2. **Verify**: the window closes and the buffer now shows the edited code. Confirm
   the change actually satisfies the prompt, lands in the intended region, and
   leaves the outside-selection sentinels untouched.
3. **Undo**: press `u` to restore the buffer before the next step.

> `<S-CR>` needs a terminal that distinguishes Shift+Enter (kitty keyboard
> protocol / `modifyOtherKeys`). Through a PTY that can't send it, set a sendable
> confirm key for the run: `require("askai").setup({ keys = { confirm = "<C-a>" } })`.

## Test matrix (run top-to-bottom in one session)

Each method runs with-selection → no-selection (stale check ★) for both intents.
Replace *INFO* / *ACTION* with a prompt you generate fresh for that category.

### Method A — command with inline question: `:AskAI {prompt}`

| #  | Sel | Use    | Steps                                              |
| -- | --- | ------ | -------------------------------------------------- |
| A1 | yes | INFO   | `14G` `V4j` `:` then `AskAI {INFO}` ⏎              |
| A2 | no  | INFO   | `:AskAI {INFO} (about the whole file)` ⏎           |
| A3 | yes | ACTION | `14G` `V4j` `:` then `AskAI {ACTION}` ⏎            |
| A4 | no  | ACTION | `:AskAI {ACTION} (in M.greet)` ⏎                   |

### Method B — command, question via input prompt: `:AskAI` then type at `Ask AI:`

| #  | Sel | Use    | Steps                                              |
| -- | --- | ------ | -------------------------------------------------- |
| B1 | yes | INFO   | `14G` `V4j` `:` then `AskAI` ⏎, type `{INFO}` ⏎    |
| B2 | no  | INFO   | `:AskAI` ⏎, type `{INFO} (whole file)` ⏎           |
| B3 | yes | ACTION | `14G` `V4j` `:` then `AskAI` ⏎, type `{ACTION}` ⏎  |
| B4 | no  | ACTION | `:AskAI` ⏎, type `{ACTION} (in M.status)` ⏎        |

### Method C — Lua API via keybind: `<leader>ai` (always prompts for question)

| #  | Sel | Use    | Steps                                              |
| -- | --- | ------ | -------------------------------------------------- |
| C1 | yes | INFO   | `14G` `V4j` then `<leader>ai`, type `{INFO}` ⏎     |
| C2 | no  | INFO   | `<leader>ai`, type `{INFO} (whole file)` ⏎         |
| C3 | yes | ACTION | `14G` `V4j` then `<leader>ai`, type `{ACTION}` ⏎   |
| C4 | no  | ACTION | `<leader>ai`, type `{ACTION} (in M.greet)` ⏎       |

### Multi-edit case (run once per session, no selection)

`:AskAI {MULTI}` ⏎ — a request that should affect many lines at once.

Expected: a diff that satisfies the request across the file, applied either as one
`edit_all` (a shared pattern, e.g. `print("`) or as several edits. After accept,
**every** targeted string must be changed (e.g. all `print(...)` lines), not just
the first one.

> **Known model limitation.** The plugin sends a *single* request and applies
> whatever tool calls come back. Some models — including `mercury-2` and the free
> `gpt-oss-120b` — return **at most one tool call per turn**. They therefore handle
> "all X" only when a single `edit_all` with a shared `oldString` covers every
> case; if the targets differ, they tend to edit just the first. A single-change
> result here is usually the model, not a bug. **Confirm before filing a bug:**
> re-issue the same request straight to the provider and inspect
> `.choices[0].message.tool_calls | length`. If the API itself returns one call,
> it's the model. Our edit/diff/apply code is verified to handle N tool calls
> correctly when a model returns them.

## Pass criteria

- [ ] Every INFO request opens a dismiss-only summary window; its answer addresses
      the selected region (with selection) or the whole file (no selection).
- [ ] Every ACTION/MULTI request opens an accept/dismiss diff window.
- [ ] Accepting applies the edit exactly as shown, satisfies the prompt, and after
      undo the buffer is byte-for-byte back to original.
- [ ] Every **with-selection** edit stays inside lines 14–18; the `log`, `M.greet`
      and `M.status` sentinels are untouched.
- [ ] Every **no-selection** request (★) operates on the whole file and is **never**
      limited to the previously selected region — confirms no stale selection leak.
- [ ] Intent classification matches the prompt (questions → informational,
      change requests → action).
- [ ] MULTI: every targeted occurrence is changed, OR (if only one is) the raw API
      response confirms the model returned a single tool call.
```
