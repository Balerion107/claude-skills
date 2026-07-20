# Model Council + Fusion — Project Plan

Goal: route every task to the best model for it (Fable 5 for hard
agentic/coding work, cheaper/faster models for simple tasks), optionally fan a
task out to several models and fuse the answers — integrated with Claude Code,
your `.claude/` memory, and your Windows workflow (IBKR trading, engineering,
agents).

`model_council.py` in this folder is Phase 0/1, already working. Everything
below builds on it without rewrites.

## Architecture

```
            +----------------------+
 task ----> |  Router              |  rule-based today; judge/embedding later
            |  (choose_model)      |
            +----------+-----------+
                       |
        +--------------+---------------+
        |         (single)             |  (council fan-out, parallel)
        v                              v
  +-----------+              +-----------------------+
  | Executor  |              | Executor x N          |
  | 1 model   |              | fable-5, sonnet-5, .. |
  +-----+-----+              +-----------+-----------+
        |                                |
        |                       +--------v--------+
        |                       | Fusion judge    |  synthesize / adjudicate
        |                       | (fable-5)       |
        |                       +--------+--------+
        v                                v
  +-------------------------------------------------+
  | Cost ledger + result log (JSONL)                |
  | Shared memory (.claude/memory/council-notes.md) |
  +-------------------------------------------------+
```

## Phases

### Phase 0 — Starter (DONE, this folder)
- Deterministic keyword router, live/simulate executor, parallel fan-out,
  judge fusion, `--json` output, non-dated model aliases.
- Simulation mode is the default without a key: develop routing/fusion logic
  at zero cost (mirrors the skillopt-sleep `mock`-backend pattern).

### Phase 1 — Make it trustworthy (~1 evening)
1. Fill in the pricing table (`price_in`/`price_out`) from
   https://docs.claude.com/en/docs/about-claude/pricing — until then costs
   report "unknown" rather than made-up numbers.
2. Append every run to `council_ledger.jsonl` (task hash, model, tokens, cost,
   duration). One function; the dataclasses already carry the fields.
3. Add `--budget-usd` that refuses a run when the ledger's rolling daily spend
   would exceed it. Terminal state: REFUSED-BUDGET.

### Phase 2 — Smarter routing (~1 evening)
1. Two-stage router: Haiku classifies the task (`{lane, complexity,
   needs_tools}` JSON) for ~fractions of a cent, then a lookup table maps the
   classification to a model. Keep the keyword router as offline fallback.
2. Route-explanation output (`--explain`): print why a model was chosen.
   Never silently escalate to premium models — surface it.

### Phase 3 — Claude Code integration (~1 evening)
1. Project skill `.claude/skills/model-council/SKILL.md`: teach Claude Code
   when to shell out to the council (second opinions, cheap bulk transforms,
   cross-checking risky changes).
2. Slash command `/council <task>` in `.claude/commands/council.md` that runs
   `python model_council.py "$ARGUMENTS" --council claude-fable-5,claude-sonnet-5 --fuse`.
3. Council notes: fused answers worth keeping get appended to
   `.claude/memory/council-notes.md` so future sessions inherit them.

### Phase 4 — Fusion strategies (as needed)
- `synthesize` (current): judge merges all answers.
- `adjudicate`: judge picks ONE winner and says why (better for code where
  merging two implementations produces Frankenstein diffs).
- `specialist-merge`: one model writes code, another reviews it, judge applies
  review to code. Highest value for your use case; wire as
  `--strategy specialist-merge` with fixed roles.
- `debate` (optional, expensive): two rounds where each model sees the others'
  answers before the judge rules.

### Phase 5 — Local lane (optional, your hardware supports it)
The Ryzen AI 9 HX 375 has an NPU + strong iGPU. Add a `local` entry to MODELS
that calls an OpenAI-compatible local server (LM Studio, Ollama, or AMD's
Lemonade server with NPU offload) for free draft/classification passes; keep
Claude models for anything that ships. The executor only needs a second code
path: same request shape, different base URL.

### Phase 6 — Agent SDK version (when the CLI outgrows you)
Rebuild the executor on `claude-agent-sdk` (already installed by
`Install-ClaudeCodeEnvironment.ps1`) so council members can use tools
(file access, bash) instead of text-only completions. The router, ledger, and
fusion layers carry over unchanged — that is why they are separate functions.

## Hard rules (keep these as the system grows)
- Every premium-model call must be explainable: log why the router escalated.
- Fusion never hides disagreement: if council members contradict, the fused
  output must name the disagreement.
- Budget gate refuses, never silently downgrades.
- Simulation mode must always keep working — it is the test harness.

## First next action
Run Phase 1 items 1–2, then ask Claude Code (with this folder open):
"Implement Phase 2 of windows-setup/model-council/MODEL-COUNCIL-PLAN.md —
the two-stage Haiku router with --explain — extending model_council.py
without breaking --simulate."
