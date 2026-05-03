### PR Review Bot

This repo uses [Momus](https://github.com/axiomantic/momus) running via the
reusable workflow at [`elijahr/.github`](https://github.com/elijahr/.github).

- **Author:** the workflow posts as the GitHub token user (typically `elijahr` or `github-actions[bot]`).
- **Auto-reviews:** runs on PR `opened`, `reopened`, `ready_for_review`, and `synchronize`.
- **Re-review:** comment `/ai-review` on a PR to re-run the review on the latest changes. Prior findings are remembered (PENDING / DECLINED / PARTIAL_AGREEMENT / ALTERNATIVE_PROPOSED / ANSWERED).
- **Decline a finding:** reply to a finding's inline comment with `won't fix`, `by design`, or `not a bug`.
- **Propose an alternative:** reply with `instead, ...`.
- **Default model:** OpenRouter / DeepSeek V4 Pro (configurable via the reusable workflow's `model` input).
