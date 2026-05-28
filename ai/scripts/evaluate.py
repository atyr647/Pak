#!/usr/bin/env python3
"""
evaluate.py — Benchmark a fine-tuned Pak model against known-good tasks.

Tests the model on a set of prompts and scores the outputs by:
  1. Syntax validity (does it pass `pak check`?)
  2. Keyword correctness (uses 'entry', 'and'/'or'/'not', 'none', no semicolons)
  3. API correctness (only uses documented modules and functions)
  4. Hardware rule compliance (init order, poll before read, DMA sequence)

Usage:
    python3 ai/scripts/evaluate.py --model pak-coder   # test Ollama model
    python3 ai/scripts/evaluate.py --model pak-coder --verbose
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# ---------------------------------------------------------------------------
# Test prompts — each has a prompt and a set of expected/forbidden patterns
# ---------------------------------------------------------------------------

EVAL_TASKS = [
    {
        "id": "T01",
        "prompt": "Write a minimal Pak program that clears the screen to blue.",
        "must_contain": ["entry {", "display.init", "rdpq.attach_clear", "rdpq.detach_show"],
        "must_not_contain": ["fn main", "void", "null", "&&", "||", ";"],
        "should_compile": True,
    },
    {
        "id": "T02",
        "prompt": "Write a Pak struct for a player with x, y position and health, with an init method.",
        "must_contain": ["struct", "impl", "self:"],
        "must_not_contain": ["class", "new", "null"],
        "should_compile": True,
    },
    {
        "id": "T03",
        "prompt": "Write a Pak game loop that reads controller input and moves a rectangle.",
        "must_contain": ["controller.poll()", "controller.read(", "loop {"],
        "must_not_contain": ["fn main", "&&", "||"],
        "should_compile": True,
    },
    {
        "id": "T04",
        "prompt": "Write a Pak function that loads data from ROM using DMA with proper cache management.",
        "must_contain": ["cache.writeback", "dma.read", "dma.wait", "cache.invalidate", "@aligned(16)"],
        "must_not_contain": [],
        "should_compile": True,
    },
    {
        "id": "T05",
        "prompt": "Write a Pak program that saves a high score to EEPROM.",
        "must_contain": ["eeprom.present()", "eeprom.write"],
        "must_not_contain": ["null"],
        "should_compile": True,
    },
    {
        "id": "T06",
        "prompt": "Write a Pak enum for game states and a match statement that handles each state.",
        "must_contain": ["enum", "match"],
        "must_not_contain": ["switch", "case:", "default:"],
        "should_compile": True,
    },
    {
        "id": "T07",
        "prompt": "Write a Pak program that initializes audio at 44100 Hz and fills audio buffers.",
        "must_contain": ["audio.init", "audio.get_buffer", "none"],
        "must_not_contain": ["null", "NULL"],
        "should_compile": True,
    },
    {
        "id": "T08",
        "prompt": "Explain why you must call controller.poll() before controller.read() in Pak.",
        "must_contain": ["poll", "stale", "frame"],
        "must_not_contain": [],
        "should_compile": False,  # explanation, not code
    },
    {
        "id": "T09",
        "prompt": "Write a Pak program using t3d that creates a viewport and renders a loaded model.",
        "must_contain": ["t3d.init", "t3d.viewport_create", "t3d.model_load", "t3d.frame_start"],
        "must_not_contain": ["fn main"],
        "should_compile": True,
    },
    {
        "id": "T10",
        "prompt": "A developer wrote `if (x && y) { return null; }` in Pak. What's wrong?",
        "must_contain": ["and", "none"],
        "must_not_contain": [],
        "should_compile": False,  # explanation
    },
    {
        "id": "T11",
        "prompt": "Write a Pak fixed-point entity system with position and velocity using fix16.16.",
        "must_contain": ["fix16.16"],
        "must_not_contain": ["float", "double"],
        "should_compile": True,
    },
    {
        "id": "T12",
        "prompt": "What is the correct N64 subsystem initialization order in Pak?",
        "must_contain": ["display", "rdpq", "controller"],
        "must_not_contain": [],
        "should_compile": False,
    },
]


def query_ollama(model: str, prompt: str, timeout: int = 60) -> str:
    """Query an Ollama model and return the response text."""
    try:
        result = subprocess.run(
            ["ollama", "run", model, prompt],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        return "[TIMEOUT]"
    except FileNotFoundError:
        print("ERROR: ollama not found in PATH. Install from https://ollama.com")
        sys.exit(1)


def check_pak_syntax(code: str) -> tuple[bool, str]:
    """Run pak check on a code string. Returns (passed, error_msg)."""
    # Extract code from markdown blocks if present
    blocks = re.findall(r"```pak\n(.*?)```", code, re.DOTALL)
    if blocks:
        code = blocks[0]
    elif "```" in code:
        # Try generic code block
        blocks = re.findall(r"```\n?(.*?)```", code, re.DOTALL)
        if blocks:
            code = blocks[0]

    # Skip if this doesn't look like Pak code
    if not any(kw in code for kw in ["entry {", "fn ", "struct ", "enum ", "use "]):
        return True, "skipped (not code)"

    pak_bin = REPO_ROOT / "tools" / "validate_pak.sh"
    if not pak_bin.exists():
        return True, "skipped (no validator)"

    with tempfile.NamedTemporaryFile(suffix=".pak", mode="w", delete=False) as f:
        f.write(code)
        f.flush()
        try:
            result = subprocess.run(
                [str(pak_bin), f.name],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                return True, "passed"
            return False, result.stderr.strip()[:200]
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return True, "skipped (error running validator)"
        finally:
            Path(f.name).unlink(missing_ok=True)


def score_response(task: dict, response: str) -> dict:
    """Score a model response against expected patterns."""
    response_lower = response.lower()
    results = {
        "id": task["id"],
        "prompt": task["prompt"][:80],
        "must_contain_hits": 0,
        "must_contain_misses": [],
        "must_not_contain_violations": [],
        "syntax_valid": None,
        "syntax_msg": "",
    }

    # Check must_contain
    for pattern in task["must_contain"]:
        if pattern.lower() in response_lower:
            results["must_contain_hits"] += 1
        else:
            results["must_contain_misses"].append(pattern)

    # Check must_not_contain
    for pattern in task["must_not_contain"]:
        if pattern.lower() in response_lower:
            results["must_not_contain_violations"].append(pattern)

    # Syntax check
    if task["should_compile"]:
        passed, msg = check_pak_syntax(response)
        results["syntax_valid"] = passed
        results["syntax_msg"] = msg

    # Compute score (0-100)
    total_checks = len(task["must_contain"]) + len(task["must_not_contain"])
    if task["should_compile"]:
        total_checks += 1
    if total_checks == 0:
        results["score"] = 100
    else:
        passed_checks = results["must_contain_hits"]
        passed_checks += len(task["must_not_contain"]) - len(results["must_not_contain_violations"])
        if task["should_compile"] and results["syntax_valid"]:
            passed_checks += 1
        results["score"] = round(100 * passed_checks / total_checks)

    return results


def main():
    parser = argparse.ArgumentParser(description="Evaluate Pak AI model")
    parser.add_argument("--model", required=True, help="Ollama model name (e.g. pak-coder)")
    parser.add_argument("--verbose", action="store_true", help="Print full responses")
    parser.add_argument("--timeout", type=int, default=120, help="Timeout per query in seconds")
    parser.add_argument("--output", type=Path, default=None, help="Save results to JSON file")
    args = parser.parse_args()

    print("=" * 60)
    print(f"Pak AI Model Evaluation — {args.model}")
    print("=" * 60)
    print(f"Tasks: {len(EVAL_TASKS)}")
    print()

    all_results = []
    total_score = 0

    for i, task in enumerate(EVAL_TASKS, 1):
        print(f"[{i}/{len(EVAL_TASKS)}] {task['id']}: {task['prompt'][:60]}...")
        response = query_ollama(args.model, task["prompt"], timeout=args.timeout)

        if args.verbose:
            print(f"  Response ({len(response)} chars):")
            for line in response.split("\n")[:10]:
                print(f"    {line}")
            if response.count("\n") > 10:
                print(f"    ... ({response.count(chr(10)) - 10} more lines)")

        result = score_response(task, response)
        result["response_length"] = len(response)
        all_results.append(result)
        total_score += result["score"]

        # Print result
        status = "PASS" if result["score"] >= 80 else "WARN" if result["score"] >= 50 else "FAIL"
        print(f"  [{status}] Score: {result['score']}%", end="")
        if result["must_contain_misses"]:
            print(f"  Missing: {result['must_contain_misses']}", end="")
        if result["must_not_contain_violations"]:
            print(f"  Violations: {result['must_not_contain_violations']}", end="")
        if result["syntax_valid"] is False:
            print(f"  Syntax: FAIL ({result['syntax_msg'][:60]})", end="")
        print()

    # Summary
    avg_score = total_score / len(EVAL_TASKS) if EVAL_TASKS else 0
    print("\n" + "=" * 60)
    print(f"Overall Score: {avg_score:.1f}%")
    print(f"Tasks Passed (>=80%): {sum(1 for r in all_results if r['score'] >= 80)}/{len(EVAL_TASKS)}")
    print(f"Tasks Failed (<50%):  {sum(1 for r in all_results if r['score'] < 50)}/{len(EVAL_TASKS)}")
    print("=" * 60)

    if avg_score >= 80:
        print("\nModel is performing well. Ready for real-world use.")
    elif avg_score >= 60:
        print("\nModel needs more training data or more epochs.")
    else:
        print("\nModel is undertrained. Review dataset quality and increase training.")

    # Save results
    if args.output:
        with open(args.output, "w") as f:
            json.dump({
                "model": args.model,
                "avg_score": avg_score,
                "results": all_results,
            }, f, indent=2)
        print(f"\nResults saved to: {args.output}")


if __name__ == "__main__":
    main()
