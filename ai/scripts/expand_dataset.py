#!/usr/bin/env python3
"""
expand_dataset.py — Combine all generators to build the full training dataset.

Merges:
  - Seed data from prepare_data.py (docs + canonical examples)
  - Rephrasings of core concepts
  - Bug-fix pairs (broken code + fix)
  - Exhaustive hardware knowledge
  - API usage combos for every module/function
  - Full game .pak files from ai/dataset/games/

Output: ai/dataset/full_dataset.jsonl

Usage:
    python3 ai/scripts/expand_dataset.py
    python3 ai/scripts/expand_dataset.py --validate   # also run pak check on outputs
    python3 ai/scripts/expand_dataset.py --stats       # just print stats, no write
"""

import json
import sys
from pathlib import Path

# Add scripts dir to path for generator imports
SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

from generators.rephrasings import gen_rephrasings
from generators.bugfixes import gen_bugfixes
from generators.hardware import gen_hardware
from generators.api_combos import gen_api_combos
from generators.game_examples import gen_game_examples
from generators.patterns import gen_patterns
from generators.libdragon_deep import gen_libdragon_deep
from generators.libdragon_audio import gen_libdragon_audio
from generators.t3d_deep import gen_t3d_deep
from generators.n64_c_patterns import gen_n64_c_patterns
from generators.complex_architecture import gen_complex_architecture
from generators.performance_optimization import gen_performance_optimization
from generators.advanced_architecture import gen_advanced_architecture
from generators.troubleshooting import gen_troubleshooting
from generators.integrated_games import gen_integrated_games

REPO_ROOT = SCRIPTS_DIR.parent.parent
DATASET_DIR = REPO_ROOT / "ai" / "dataset"
SEED_FILE = DATASET_DIR / "seed_dataset.jsonl"
OUTPUT_FILE = DATASET_DIR / "full_dataset.jsonl"


def load_seed() -> list[dict]:
    """Load the seed dataset from prepare_data.py."""
    if not SEED_FILE.exists():
        print(f"WARNING: Seed file not found at {SEED_FILE}")
        print(f"Run prepare_data.py first: python3 ai/scripts/prepare_data.py")
        return []

    pairs = []
    with open(SEED_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                pairs.append(json.loads(line))
    return pairs


def deduplicate(pairs: list[dict]) -> list[dict]:
    """Remove exact duplicate instructions."""
    seen = set()
    unique = []
    for p in pairs:
        key = p["instruction"].strip().lower()
        if key not in seen:
            seen.add(key)
            unique.append(p)
    return unique


def main():
    stats_only = "--stats" in sys.argv
    validate = "--validate" in sys.argv

    print("=" * 60)
    print("Pak AI — Full Dataset Builder")
    print("=" * 60)

    all_pairs = []

    generators = [
        ("Seed (docs + canonical)", load_seed),
        ("Rephrasings", gen_rephrasings),
        ("Bug Fixes", gen_bugfixes),
        ("Hardware Knowledge", gen_hardware),
        ("API Usage Combos", gen_api_combos),
        ("Game Examples (.pak files)", gen_game_examples),
        ("Game Dev Patterns", gen_patterns),
        ("Libdragon Deep (rdpq, sprites, FS, save)", gen_libdragon_deep),
        ("Libdragon Audio (mixer, wav64, xm64)", gen_libdragon_audio),
        ("Tiny3D Deep (pipeline, animation, math)", gen_t3d_deep),
        ("N64 C Patterns (extern, transpilation)", gen_n64_c_patterns),
        ("Complex Architecture (AI, physics, inventory)", gen_complex_architecture),
        ("Performance Optimization (RAM, TMEM, FPS)", gen_performance_optimization),
        ("Advanced Architecture (state machines, events)", gen_advanced_architecture),
        ("Troubleshooting (bugs, glitches, crashes)", gen_troubleshooting),
        ("Integrated Multi-System Examples", gen_integrated_games),
    ]

    for name, gen_fn in generators:
        pairs = gen_fn()
        all_pairs.extend(pairs)
        print(f"  {name}: {len(pairs)} pairs")

    # Deduplicate
    before = len(all_pairs)
    all_pairs = deduplicate(all_pairs)
    dupes = before - len(all_pairs)
    if dupes > 0:
        print(f"\n  Removed {dupes} duplicate instructions")

    print(f"\nTotal unique pairs: {len(all_pairs)}")

    # Category breakdown
    categories = {}
    for p in all_pairs:
        cat = p.get("category", "unknown")
        categories[cat] = categories.get(cat, 0) + 1
    print("\nBy category:")
    for cat, count in sorted(categories.items()):
        print(f"  {cat:20s} {count:4d}")

    # Source breakdown
    sources = {}
    for p in all_pairs:
        src = p.get("source", "unknown")
        if "/" in src:
            src = src.split("/")[0]
        sources[src] = sources.get(src, 0) + 1
    print("\nBy source:")
    for src, count in sorted(sources.items()):
        print(f"  {src:20s} {count:4d}")

    if stats_only:
        print("\n[--stats] Stats only, no file written.")
        return

    # Validation
    if validate:
        print("\nValidating Pak outputs...")
        import subprocess
        import tempfile
        import re

        pak_validator = REPO_ROOT / "tools" / "validate_pak.sh"
        if not pak_validator.exists():
            print("  validate_pak.sh not found, skipping validation")
        else:
            passed = failed = skipped = 0
            for p in all_pairs:
                output = p["output"]
                # Skip non-code outputs
                if "```" in output[:20] or output.startswith("In Pak") or "|" in output[:30]:
                    skipped += 1
                    continue
                if not any(kw in output for kw in ["entry {", "fn ", "struct ", "enum "]):
                    skipped += 1
                    continue

                with tempfile.NamedTemporaryFile(suffix=".pak", mode="w", delete=False) as f:
                    f.write(output)
                    f.flush()
                    try:
                        result = subprocess.run(
                            [str(pak_validator), f.name],
                            capture_output=True, text=True, timeout=10
                        )
                        if result.returncode == 0:
                            passed += 1
                        else:
                            failed += 1
                            print(f"  FAIL: {p['instruction'][:60]}...")
                    except Exception:
                        skipped += 1
                    finally:
                        Path(f.name).unlink(missing_ok=True)

            print(f"  Passed: {passed}, Failed: {failed}, Skipped: {skipped}")

    # Write output
    DATASET_DIR.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        for pair in all_pairs:
            f.write(json.dumps({
                "instruction": pair["instruction"],
                "output": pair["output"],
                "source": pair.get("source", ""),
                "category": pair.get("category", ""),
            }, ensure_ascii=False) + "\n")

    size_kb = OUTPUT_FILE.stat().st_size / 1024
    print(f"\nDataset written to: {OUTPUT_FILE}")
    print(f"File size: {size_kb:.1f} KB")
    print("=" * 60)


if __name__ == "__main__":
    main()
