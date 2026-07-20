#!/usr/bin/env python3
"""Model Council + Fusion — working starter, upgraded from the stub version.

Routes a task to the best Claude model, or fans it out to several models in
parallel and fuses the answers with a judge model.

Works in two modes:
  * LIVE      — `pip install anthropic` and set ANTHROPIC_API_KEY. Real calls.
  * SIMULATE  — no key / no package / --simulate flag. Deterministic fake
                outputs, clearly labeled, so the routing/fusion plumbing can be
                developed and tested for free.

Usage:
  python model_council.py "Refactor my PowerShell git fixer for speed"
  python model_council.py "Summarize this file" --model claude-haiku-4-5
  python model_council.py "Design the trading agent" --council claude-fable-5,claude-sonnet-5 --fuse
  python model_council.py "anything" --simulate --json

Design notes:
  - Registry + router are deliberately simple and deterministic; replace
    choose_model() with an embedding or judge-based router later (see
    MODEL-COUNCIL-PLAN.md, Phase 2).
  - Pricing is a user-editable table. Entries left as None report "unknown"
    instead of inventing numbers; fill them in from
    https://docs.claude.com/en/docs/about-claude/pricing
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field, asdict
from typing import Optional

# ----------------------------------------------------------------------------
# Model registry — non-dated aliases so this file doesn't rot with releases.
# ----------------------------------------------------------------------------
MODELS: dict[str, dict] = {
    "claude-fable-5": {
        "label": "Claude Fable 5",
        "strengths": ["complex coding", "agentic work", "long-horizon planning",
                      "architecture", "windows troubleshooting", "first-shot implementation"],
        "cost_tier": "premium",
        "speed": "medium",
        # USD per million tokens (input, output). None = unknown; fill in from docs.
        "price_in": None, "price_out": None,
        "max_output_tokens": 8192,
    },
    "claude-opus-4-8": {
        "label": "Claude Opus 4.8",
        "strengths": ["complex coding", "review", "deep analysis"],
        "cost_tier": "high",
        "speed": "medium",
        "price_in": None, "price_out": None,
        "max_output_tokens": 8192,
    },
    "claude-sonnet-5": {
        "label": "Claude Sonnet 5",
        "strengths": ["balanced", "fast coding", "summarization", "drafting"],
        "cost_tier": "medium",
        "speed": "fast",
        "price_in": None, "price_out": None,
        "max_output_tokens": 8192,
    },
    "claude-haiku-4-5": {
        "label": "Claude Haiku 4.5",
        "strengths": ["classification", "extraction", "simple transforms", "cheap volume"],
        "cost_tier": "low",
        "speed": "fastest",
        "price_in": None, "price_out": None,
        "max_output_tokens": 4096,
    },
}

DEFAULT_JUDGE = "claude-fable-5"

# Keyword → model routing signals. Deterministic and inspectable on purpose.
HARD_SIGNALS = ("architect", "agent", "implement", "refactor", "long", "complex",
                "troubleshoot", "fix git", "migrate", "design", "trading", "multi-step")
FAST_SIGNALS = ("summarize", "classify", "extract", "list", "rename", "translate",
                "one-liner", "quick", "simple")


def choose_model(task: str, prefer_speed: bool = False) -> str:
    """Rule-based router. Returns a model key from MODELS."""
    text = task.lower()
    hard = sum(1 for kw in HARD_SIGNALS if kw in text)
    fast = sum(1 for kw in FAST_SIGNALS if kw in text)
    if hard > fast:
        return "claude-fable-5"
    if fast > hard:
        return "claude-haiku-4-5" if prefer_speed else "claude-sonnet-5"
    return "claude-sonnet-5" if prefer_speed else "claude-fable-5"


# ----------------------------------------------------------------------------
# Execution
# ----------------------------------------------------------------------------
@dataclass
class ModelResult:
    model: str
    output: str
    input_tokens: int = 0
    output_tokens: int = 0
    seconds: float = 0.0
    simulated: bool = False
    error: Optional[str] = None
    cost_usd: Optional[float] = None


def _estimate_cost(model: str, tokens_in: int, tokens_out: int) -> Optional[float]:
    spec = MODELS[model]
    if spec["price_in"] is None or spec["price_out"] is None:
        return None
    return round((tokens_in * spec["price_in"] + tokens_out * spec["price_out"]) / 1_000_000, 6)


def _live_client():
    """Return an Anthropic client, or None if live mode is unavailable."""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return None
    try:
        from anthropic import Anthropic  # optional dependency
    except ImportError:
        return None
    return Anthropic()


def run_task_on_model(task: str, model_key: str, system: str = "",
                      simulate: bool = False) -> ModelResult:
    if model_key not in MODELS:
        return ModelResult(model=model_key, output="", error=f"unknown model {model_key!r}")

    start = time.monotonic()
    client = None if simulate else _live_client()

    if client is None:
        # Deterministic simulation: same task+model always yields the same text,
        # so fusion logic is testable without spending a cent.
        digest = hashlib.sha256(f"{model_key}:{task}".encode()).hexdigest()[:8]
        output = (f"[SIMULATED {MODELS[model_key]['label']} response {digest}] "
                  f"Approach for: {task[:120]} — (set ANTHROPIC_API_KEY and "
                  f"`pip install anthropic` for live output)")
        return ModelResult(model=model_key, output=output, simulated=True,
                           seconds=round(time.monotonic() - start, 3))

    try:
        message = client.messages.create(
            model=model_key,
            max_tokens=MODELS[model_key]["max_output_tokens"],
            system=system or "You are a precise, senior technical assistant. Be direct.",
            messages=[{"role": "user", "content": task}],
        )
        text = "".join(block.text for block in message.content if block.type == "text")
        t_in = message.usage.input_tokens
        t_out = message.usage.output_tokens
        return ModelResult(
            model=model_key, output=text,
            input_tokens=t_in, output_tokens=t_out,
            seconds=round(time.monotonic() - start, 3),
            cost_usd=_estimate_cost(model_key, t_in, t_out),
        )
    except Exception as exc:  # network/auth/rate-limit — report, don't crash the council
        return ModelResult(model=model_key, output="", error=str(exc),
                           seconds=round(time.monotonic() - start, 3))


def run_council(task: str, models: list[str], system: str = "",
                simulate: bool = False) -> list[ModelResult]:
    """Fan the task out to several models in parallel."""
    results: list[ModelResult] = []
    with ThreadPoolExecutor(max_workers=max(1, len(models))) as pool:
        futures = {pool.submit(run_task_on_model, task, m, system, simulate): m for m in models}
        for fut in as_completed(futures):
            results.append(fut.result())
    # Preserve caller's model order in the output.
    order = {m: i for i, m in enumerate(models)}
    results.sort(key=lambda r: order.get(r.model, 99))
    return results


def fuse_outputs(task: str, results: list[ModelResult], judge: str = DEFAULT_JUDGE,
                 simulate: bool = False) -> ModelResult:
    """Send all council outputs to a judge model to synthesize one best answer."""
    usable = [r for r in results if r.output and not r.error]
    if not usable:
        return ModelResult(model=judge, output="", error="no usable council outputs to fuse")
    if len(usable) == 1:
        return usable[0]

    sections = "\n\n".join(
        f"### Response from {MODELS.get(r.model, {}).get('label', r.model)}\n{r.output}"
        for r in usable
    )
    fusion_prompt = (
        "You are the fusion judge of a model council. Multiple models answered "
        "the same task. Synthesize the single best answer: keep the strongest "
        "reasoning and correct any model that contradicts another (say which, "
        "briefly). Output only the final fused answer.\n\n"
        f"## Original task\n{task}\n\n## Council responses\n{sections}"
    )
    return run_task_on_model(fusion_prompt, judge, simulate=simulate)


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Model Council: route a task to the best Claude model, or "
                    "fan out to several and fuse the answers.")
    parser.add_argument("task", help="the task / prompt to run")
    parser.add_argument("--model", help="force a specific model (skips the router)")
    parser.add_argument("--council", help="comma-separated model keys to fan out to")
    parser.add_argument("--fuse", action="store_true",
                        help="with --council: synthesize one answer via the judge model")
    parser.add_argument("--judge", default=DEFAULT_JUDGE,
                        help=f"judge model for --fuse (default {DEFAULT_JUDGE})")
    parser.add_argument("--system", default="", help="optional system prompt")
    parser.add_argument("--prefer-speed", action="store_true",
                        help="router bias toward faster/cheaper models")
    parser.add_argument("--simulate", action="store_true",
                        help="force simulation even if an API key is configured")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--list-models", action="store_true", help="show the registry and exit")
    args = parser.parse_args(argv)

    if args.list_models:
        print(json.dumps(MODELS, indent=2))
        return 0

    for key in ([args.model] if args.model else []) + \
               (args.council.split(",") if args.council else []):
        if key and key.strip() not in MODELS:
            print(f"error: unknown model {key.strip()!r}. Known: {', '.join(MODELS)}",
                  file=sys.stderr)
            return 2

    live_available = _live_client() is not None and not args.simulate
    mode = "LIVE" if live_available else "SIMULATE"
    print(f"[council] mode={mode}", file=sys.stderr)

    payload: dict = {"mode": mode, "task": args.task}

    if args.council:
        members = [m.strip() for m in args.council.split(",") if m.strip()]
        print(f"[council] fan-out -> {', '.join(members)}", file=sys.stderr)
        results = run_council(args.task, members, args.system, simulate=not live_available)
        payload["council"] = [asdict(r) for r in results]
        if args.fuse:
            print(f"[council] fusing via {args.judge}", file=sys.stderr)
            fused = fuse_outputs(args.task, results, args.judge, simulate=not live_available)
            payload["fused"] = asdict(fused)
    else:
        chosen = args.model or choose_model(args.task, args.prefer_speed)
        print(f"[council] routed -> {chosen}", file=sys.stderr)
        result = run_task_on_model(args.task, chosen, args.system, simulate=not live_available)
        payload["result"] = asdict(result)

    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        if "result" in payload:
            r = payload["result"]
            _print_result(r)
        if "council" in payload:
            for r in payload["council"]:
                print(f"\n----- {r['model']} -----")
                _print_result(r)
        if "fused" in payload:
            print("\n===== FUSED ANSWER =====")
            _print_result(payload["fused"])

    # Non-zero exit if everything errored (useful for scripting).
    all_results = ([payload.get("result")] if "result" in payload else []) + \
                  payload.get("council", [])
    if all_results and all(r.get("error") for r in all_results if r):
        return 1
    return 0


def _print_result(r: dict) -> None:
    if r.get("error"):
        print(f"[error] {r['error']}")
        return
    print(r["output"])
    meta = f"[{r['model']} | {r['seconds']}s"
    if r.get("input_tokens"):
        meta += f" | {r['input_tokens']}->{r['output_tokens']} tok"
    if r.get("cost_usd") is not None:
        meta += f" | ${r['cost_usd']}"
    elif not r.get("simulated"):
        meta += " | cost unknown (fill price table)"
    print(meta + "]", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
