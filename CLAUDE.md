### PR Review Bot

This repo uses [Qodo PR-Agent](https://github.com/qodo-ai/pr-agent) running via the
reusable workflow at [`elijahr/.github`](https://github.com/elijahr/.github)
(or `axiomantic/.github` for axiomantic-namespaced repos).

- **Author:** `github-actions[bot]` (the action runs in CI; @-mentions don't work, use slash commands)
- **Auto-reviews:** runs on PR `opened`, `reopened`, and `ready_for_review`. Does NOT auto-run on every push.
- **Slash commands** (post as a PR comment; only work after the workflow file is on the default branch):
  - `/review` -- re-run a full review. Optionally pass extra instructions: `/review focus on the new lock-free path`
  - `/describe` -- (re)generate the PR description
  - `/improve` -- get code improvement suggestions
  - `/ask <question>` -- ask a question about the PR
  - `/update_changelog` -- generate CHANGELOG entries
  - `/help` -- list available commands
- **Default model:** OpenRouter / DeepSeek V4 Pro, with V4 Flash and Claude Sonnet as fallbacks.
- **Note:** A separate `qodo-code-review` bot (Qodo's hosted SaaS GitHub App) may also post on PRs. Treat its output as noise; the action-driven review is the canonical one.
