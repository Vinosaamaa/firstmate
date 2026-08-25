# Coding-agent orchestrator comparison

This comparison was checked on 2026-08-25 and is intentionally date-stamped because product scope and pricing change quickly.
Official product documentation and repositories own factual capability, license, and price claims.
Reddit and X material is labeled as community evidence and is used only to expose adoption friction or user priorities, never to override an official contract.

## Comparison

| Option | Persistence and multiple sessions | Repository and worktree isolation | Backends and providers | Maturity | License | Current orchestrator price |
| --- | --- | --- | --- | --- | --- | --- |
| Firstmate | Durable disk state, persistent secondmates, resumable supported sessions, and event-driven supervision across restarts | One issue-scoped worktree per writing worker, plus explicit multi-repository workspace routing | Claude Code, Grok, Pi, pi-signed, Codex, OpenCode, Cursor, Kimi, Muse, and multiple visible session backends | Active 2026 project with broad portable and opt-in live verification, but a smaller ecosystem than the vendor products | MIT | $0; selected harness, model subscription, API, and optional hosting costs remain separate |
| Gas Town | Git-backed Beads, persistent identities, mailboxes, handoffs, and crash-safe work history across ephemeral sessions | A Town contains multiple repository Rigs, with Git-worktree-backed Hooks and isolated worker spaces | Presets include Claude, Gemini, Codex, Kiro, Cursor, Auggie, Amp, OpenCode, Copilot, Pi, and others | Ambitious and actively developed, with 17.8k GitHub stars at review time, but substantial operational vocabulary and moving parts | MIT | $0; runtime subscriptions or API usage remain separate |
| Claude Code Agent Teams | Separate teammate contexts, shared tasks and mailboxes, locally persisted task lists, and resumable session state with documented limitations | Claude offers independent worktree sessions and isolated subagents, but Agent Teams themselves do not automatically isolate teammates in worktrees | Claude models through Anthropic, Bedrock, Vertex AI, or Microsoft Foundry; teammates are Claude Code sessions | Experimental and disabled by default, with known resumption, coordination, and shutdown limitations | Commercial Anthropic product | Claude Pro $20/month; Max $100 or $200/month; API usage is pay as you go |
| Codex app | Project-organized threads, shared CLI and IDE history, long-running local or cloud tasks, and scheduled Automations | Built-in worktrees isolate agents working on one repository; projects organize parallel work across repositories | OpenAI Codex models and surfaces | Vendor-supported app introduced in February 2026, available on macOS and Windows, with multi-agent workflows still being refined | Commercial OpenAI product; the underlying Codex CLI and sandbox components are open source | Included with eligible ChatGPT plans, with Plus at $20/month and Pro tiers at $100 or $200/month; extra credits are available |
| Conductor | Multiple local sessions persist while the Mac app runs; Pro cloud workspaces continue after the app closes | One isolated workspace per session, with Git worktrees, terminals, diffs, checks, and pull-request workflow | Claude Code, Codex, Cursor, and OpenCode, with provider subscriptions or keys | Commercial product claiming more than 100k builders, with maintained docs and local plus cloud products | Proprietary commercial product | Local Free $0; Pro $50/month; Teams $60/user/month; model usage remains separate |

## Official evidence

- Firstmate's current repository, [architecture](../architecture.md), [runtime verification](runtime-backends.md), and MIT [license](../../LICENSE) support its row.
- Gas Town's official repository documents [git-backed persistence, multi-repository Rigs, worktree-backed Hooks, runtime presets, adoption signals, and MIT licensing](https://github.com/gastownhall/gastown).
- Anthropic documents [Agent Teams as experimental with known resumption and shutdown limits](https://code.claude.com/docs/en/agent-teams), [parallel worktree isolation](https://code.claude.com/docs/en/worktrees), and [Claude Code subscription prices](https://support.anthropic.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan).
- OpenAI documents the Codex app's [parallel project threads, worktrees, platform availability, and subscription inclusion](https://openai.com/index/introducing-the-codex-app/), while the current [Codex rate card](https://help.openai.com/en/articles/20001106) explains additional usage credits.
- Conductor documents its [supported harnesses and separate provider billing](https://www.conductor.build/docs/reference/harnesses) and its [$0, $50, and $60 pricing tiers](https://www.conductor.build/pricing).

## Community evidence

- Reddit, anecdotal: one two-week Gas Town report praised crash-safe Beads and worktree isolation but reported high local resource use, orphaned processes, and steep vocabulary overhead; this supports treating Gas Town as powerful but operationally heavier, not as a capability source ([r/ClaudeCode discussion](https://www.reddit.com/r/ClaudeCode/comments/1qur3qq/spent_2_weeks_running_multiple_claude_code_agents/)).
- Reddit, anecdotal: multi-agent Codex users repeatedly describe the coordination and dependency cost of many worktrees, reinforcing that isolation still needs an owning task graph and integration policy ([r/codex discussion](https://www.reddit.com/r/codex/comments/1sc7g2x/how_are_you_actually_running_codex_at_scale/)).
- X, anecdotal: a developer running five to ten Claude Code or Codex sessions emphasized independent files, branches, and dependency trees as the practical reason worktrees became important for agent workflows ([X post](https://x.com/chenchengpro/status/2032411474703053012)).
- X, anecdotal: a Codex versus Claude Agent Teams comparison highlighted the architectural distinction between parent-mediated subagents and direct teammate messaging; the post also labeled both approaches experimental at that time ([X post](https://x.com/akihiro_genai/status/2026137417179365828)).

## Free-first recommendation

Start with Firstmate at $0 when the goal is durable supervision, explicit human gates, multiple repositories, and freedom to change harnesses or providers.
Start with Conductor Free instead when the priority is a polished Mac workspace and visual review rather than durable unattended local supervision.
Choose Gas Town when the work genuinely benefits from a larger persistent factory, cross-repository Rigs, and configurable workflows, and budget time for its additional operational model.
Use Claude Code Agent Teams or Codex app when tight vendor integration is worth the model lock-in and metered usage, while treating Claude teams' experimental boundary and Codex's evolving multi-agent surface as current constraints.
