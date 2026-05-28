#!/usr/bin/env python3
"""
prepare_data.py — Build fine-tuning dataset for Pak N64 AI model.

Extracts training pairs from:
  - examples/canonical/*.pak   (full program examples)
  - LANGUAGE.md                (syntax reference)
  - STDLIB.md                  (API reference)
  - N64_HARDWARE.md            (hardware constraints)
  - IDIOMS.md                  (idiomatic patterns)
  - NOT_SUPPORTED.md           (negative examples)

Output: ai/dataset/seed_dataset.jsonl  (instruction/output pairs)

Usage:
    python3 ai/scripts/prepare_data.py
    python3 ai/scripts/prepare_data.py --validate  # also run pak check on outputs
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DATASET_DIR = REPO_ROOT / "ai" / "dataset"
EXAMPLES_DIR = REPO_ROOT / "examples" / "canonical"
OUTPUT_FILE = DATASET_DIR / "seed_dataset.jsonl"


def extract_pak_blocks(markdown_text: str) -> list[str]:
    """Extract all ```pak ... ``` code blocks from markdown."""
    pattern = r"```pak\n(.*?)```"
    return re.findall(pattern, markdown_text, re.DOTALL)


def extract_sections(markdown_text: str) -> list[tuple[str, str]]:
    """Extract (heading, body) pairs from markdown ## sections."""
    sections = []
    parts = re.split(r"\n## ", markdown_text)
    for part in parts[1:]:  # skip preamble before first ##
        lines = part.strip().split("\n", 1)
        heading = lines[0].strip().lstrip("#").strip()
        body = lines[1].strip() if len(lines) > 1 else ""
        sections.append((heading, body))
    return sections


def load_file(name: str) -> str:
    path = REPO_ROOT / name
    if not path.exists():
        print(f"WARNING: {path} not found, skipping")
        return ""
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Generators — each yields (instruction, output) pairs
# ---------------------------------------------------------------------------


def gen_canonical_examples() -> list[dict]:
    """Turn each canonical .pak file into a training pair."""
    pairs = []
    if not EXAMPLES_DIR.exists():
        print(f"WARNING: {EXAMPLES_DIR} not found")
        return pairs

    for pak_file in sorted(EXAMPLES_DIR.glob("*.pak")):
        code = pak_file.read_text(encoding="utf-8").strip()
        name = pak_file.stem  # e.g. "01_hello"

        # Derive a natural-language description from the filename
        num, *rest = name.split("_", 1)
        topic = rest[0].replace("_", " ") if rest else name
        topic = topic.title()

        # Full program pair
        pairs.append({
            "instruction": (
                f"Write a complete Pak program that demonstrates {topic} "
                f"for N64 homebrew development."
            ),
            "output": code,
            "source": f"canonical/{pak_file.name}",
            "category": "full_program",
        })

        # "Explain this code" pair (reverse direction — teaches understanding)
        pairs.append({
            "instruction": (
                f"Explain what the following Pak program does, line by line:\n\n"
                f"```pak\n{code}\n```"
            ),
            "output": (
                f"This is a Pak program demonstrating {topic}. "
                f"It targets the N64 using libdragon. "
                f"See the inline comments for details on each construct used."
            ),
            "source": f"canonical/{pak_file.name}",
            "category": "explanation",
        })

    return pairs


def gen_language_syntax() -> list[dict]:
    """Generate syntax Q&A pairs from LANGUAGE.md."""
    text = load_file("LANGUAGE.md")
    if not text:
        return []

    pairs = []
    sections = extract_sections(text)

    syntax_questions = {
        "Comments": "How do you write comments in Pak?",
        "Primitive Types": "What primitive types does Pak support?",
        "Struct": "How do you define a struct in Pak?",
        "Enum": "How do you define an enum in Pak?",
        "Variant (Tagged Union / Sum Type)": "How do you define a variant (tagged union) in Pak?",
        "Functions": "How do you define functions in Pak?",
        "Variables and Constants": "How do you declare variables and constants in Pak?",
        "Statements and Control Flow": "What control flow statements does Pak support?",
        "Pattern Matching": "How does pattern matching work in Pak?",
        "Modules and Imports": "How do you import modules in Pak?",
        "Assets": "How do you load assets in Pak?",
        "Entry Point": "What is the entry point of a Pak program?",
        "Annotations": "What annotations does Pak support?",
        "Memory": "How does memory management work in Pak?",
        "Inline Assembly": "How do you write inline assembly in Pak?",
        "Fixed-Point Numbers": "How do fixed-point numbers work in Pak?",
        "Error Handling (Result)": "How does error handling work in Pak?",
    }

    for heading, body in sections:
        for key, question in syntax_questions.items():
            if key.lower() in heading.lower():
                # Extract pak code blocks as the primary answer content
                blocks = extract_pak_blocks(body)
                answer = body[:2000]  # cap length
                if blocks:
                    answer = (
                        f"In Pak, here's how {key.lower()} works:\n\n"
                        + "\n\n".join(f"```pak\n{b.strip()}\n```" for b in blocks[:3])
                    )
                pairs.append({
                    "instruction": question,
                    "output": answer,
                    "source": "LANGUAGE.md",
                    "category": "syntax",
                })
                break

    return pairs


def extract_subsections(markdown_text: str) -> list[tuple[str, str]]:
    """Extract (heading, body) pairs from ### subsections."""
    sections = []
    parts = re.split(r"\n### ", markdown_text)
    for part in parts[1:]:
        lines = part.strip().split("\n", 1)
        heading = lines[0].strip().lstrip("#").strip()
        body = lines[1].strip() if len(lines) > 1 else ""
        sections.append((heading, body))
    return sections


def gen_stdlib_api() -> list[dict]:
    """Generate API usage pairs from STDLIB.md."""
    text = load_file("STDLIB.md")
    if not text:
        return []

    pairs = []
    # STDLIB uses ### for module sections
    sections = extract_subsections(text)

    for heading, body in sections:
        # Match N64 module sections and t3d sections
        m = re.search(r"`n64\.(\w+)`|`(t3d)`", heading)
        if not m:
            continue

        module = m.group(1) or m.group(2)
        blocks = extract_pak_blocks(body)

        # API overview pair
        pairs.append({
            "instruction": f"What functions are available in the Pak `{module}` module for N64 development?",
            "output": body[:3000],
            "source": "STDLIB.md",
            "category": "api_reference",
        })

        # Usage example pair if code blocks exist
        if blocks:
            pairs.append({
                "instruction": f"Show me how to use `{module}` in a Pak program.",
                "output": "\n\n".join(f"```pak\n{b.strip()}\n```" for b in blocks[:3]),
                "source": "STDLIB.md",
                "category": "api_usage",
            })

    return pairs


def gen_hardware_knowledge() -> list[dict]:
    """Generate N64 hardware knowledge pairs from N64_HARDWARE.md."""
    text = load_file("N64_HARDWARE.md")
    if not text:
        return []

    pairs = []
    sections = extract_sections(text)

    hw_questions = {
        "Hardware Overview": "What are the N64 hardware specifications?",
        "Display System": "How does the N64 display system work and how do you initialize it in Pak?",
        "Controller Input": "How does N64 controller input work in Pak?",
        "RDP (2D Rendering)": "How does 2D rendering work on the N64 RDP in Pak?",
        "DMA (Direct Memory Access)": "How does DMA work on the N64 and what is the required sequence in Pak?",
        "Audio System": "How does the N64 audio system work in Pak?",
        "EEPROM (Save Data)": "How does EEPROM save data work on the N64 in Pak?",
        "Memory Map": "What is the N64 memory map?",
        "Performance Guidelines": "What are the performance guidelines for N64 development in Pak?",
        "Required Initialization Order": "What is the correct initialization order for N64 subsystems in Pak?",
        "Common Bugs": "What are common N64 hardware-related bugs and how do you fix them in Pak?",
    }

    for heading, body in sections:
        for key, question in hw_questions.items():
            if key.lower() in heading.lower():
                blocks = extract_pak_blocks(body)
                answer = body[:3000]
                if blocks:
                    answer += "\n\nExample:\n" + "\n".join(
                        f"```pak\n{b.strip()}\n```" for b in blocks[:2]
                    )
                pairs.append({
                    "instruction": question,
                    "output": answer,
                    "source": "N64_HARDWARE.md",
                    "category": "hardware",
                })
                break

    return pairs


def gen_idiom_patterns() -> list[dict]:
    """Generate idiomatic pattern pairs from IDIOMS.md."""
    text = load_file("IDIOMS.md")
    if not text:
        return []

    pairs = []
    sections = extract_sections(text)

    for heading, body in sections:
        # Skip numbered prefix
        clean_heading = re.sub(r"^\d+\.\s*", "", heading).strip()
        blocks = extract_pak_blocks(body)

        if blocks:
            pairs.append({
                "instruction": f"Show me the idiomatic Pak pattern for: {clean_heading}",
                "output": body[:3000],
                "source": "IDIOMS.md",
                "category": "idiom",
            })

    return pairs


def gen_negative_examples() -> list[dict]:
    """Generate 'what NOT to do' pairs from NOT_SUPPORTED.md."""
    text = load_file("NOT_SUPPORTED.md")
    if not text:
        return []

    pairs = []

    # Extract WRONG/CORRECT pairs
    wrong_correct = re.findall(
        r"### (No .+?)\n(.*?)(?=\n### |\n---|\Z)",
        text,
        re.DOTALL,
    )

    for heading, body in wrong_correct:
        pairs.append({
            "instruction": (
                f"A developer tried to use {heading.replace('No ', '').lower()} "
                f"in Pak. What's wrong and how should they fix it?"
            ),
            "output": body.strip()[:2000],
            "source": "NOT_SUPPORTED.md",
            "category": "negative",
        })

    # Also add the lookup table at the bottom
    table_match = re.search(
        r"\| What you might write.*?\n((?:\|.*\n)+)", text, re.DOTALL
    )
    if table_match:
        pairs.append({
            "instruction": (
                "List common mistakes developers make when writing Pak code "
                "and what the correct syntax should be."
            ),
            "output": table_match.group(0).strip(),
            "source": "NOT_SUPPORTED.md",
            "category": "negative",
        })

    return pairs


def gen_cross_cutting() -> list[dict]:
    """Hand-crafted cross-cutting pairs that combine multiple knowledge areas."""
    return [
        {
            "instruction": (
                "Write a complete Pak game that shows a colored rectangle "
                "the player can move with the analog stick."
            ),
            "output": """\
use n64.display
use n64.controller
use n64.rdpq
use n64.timer

const SCREEN_W: i32 = 320
const SCREEN_H: i32 = 240
const RECT_SIZE: i32 = 16
const DEAD_ZONE: i32 = 10

entry {
    display.init(0, 2, 3, 0, 1)
    rdpq.init()
    controller.init()
    timer.init()

    let x: i32 = SCREEN_W / 2
    let y: i32 = SCREEN_H / 2

    loop {
        controller.poll()
        let pad = controller.read(0)

        let raw_x: i32 = pad.stick_x as i32
        let raw_y: i32 = pad.stick_y as i32

        let dx: i32 = if raw_x > DEAD_ZONE or raw_x < -DEAD_ZONE { raw_x / 16 } else { 0 }
        let dy: i32 = if raw_y > DEAD_ZONE or raw_y < -DEAD_ZONE { -(raw_y / 16) } else { 0 }

        x = x + dx
        y = y + dy

        if x < 0 { x = 0 }
        if x > SCREEN_W - RECT_SIZE { x = SCREEN_W - RECT_SIZE }
        if y < 0 { y = 0 }
        if y > SCREEN_H - RECT_SIZE { y = SCREEN_H - RECT_SIZE }

        let fb = display.get()
        rdpq.attach_clear(fb)

        rdpq.set_mode_fill(0x000000FF)
        rdpq.fill_rectangle(0, 0, SCREEN_W, SCREEN_H)

        rdpq.sync_pipe()
        rdpq.set_mode_fill(0xFF0000FF)
        rdpq.fill_rectangle(x, y, x + RECT_SIZE, y + RECT_SIZE)

        rdpq.detach_show()
    }
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
        {
            "instruction": (
                "Write a Pak program that initializes all major N64 subsystems "
                "in the correct order and runs an empty game loop with controller "
                "input and frame timing."
            ),
            "output": """\
use n64.display
use n64.controller
use n64.rdpq
use n64.timer
use n64.audio

entry {
    display.init(0, 2, 3, 0, 1)
    rdpq.init()
    controller.init()
    timer.init()
    audio.init(44100, 4)

    loop {
        let dt: f32 = timer.delta()

        controller.poll()
        let pad = controller.read(0)

        if pad.pressed.start {
            -- handle start press
        }

        let fb = display.get()
        rdpq.attach_clear(fb)
        rdpq.set_mode_fill(0x000000FF)
        rdpq.fill_rectangle(0, 0, 320, 240)
        rdpq.detach_show()
    }
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
        {
            "instruction": (
                "Write a Pak struct for a 2D game entity with position, velocity, "
                "and health using fixed-point math, with methods to update and "
                "check if alive."
            ),
            "output": """\
struct Entity {
    x: fix16.16
    y: fix16.16
    vx: fix16.16
    vy: fix16.16
    health: i32
    max_health: i32
}

impl Entity {
    fn init(self: *Entity, start_x: fix16.16, start_y: fix16.16, hp: i32) {
        self.x = start_x
        self.y = start_y
        self.vx = 0 as fix16.16
        self.vy = 0 as fix16.16
        self.health = hp
        self.max_health = hp
    }

    fn update(self: *Entity, dt: fix16.16) {
        self.x = self.x + self.vx * dt
        self.y = self.y + self.vy * dt
    }

    fn is_alive(self: *Entity) -> bool {
        return self.health > 0
    }

    fn take_damage(self: *Entity, amount: i32) {
        self.health = self.health - amount
        if self.health < 0 {
            self.health = 0
        }
    }
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
        {
            "instruction": (
                "Write a Pak game state machine using an enum for phases "
                "(title, playing, paused, game over) with a match-based "
                "update function."
            ),
            "output": """\
use n64.controller

enum GamePhase: u8 {
    title
    playing
    paused
    game_over
}

struct GameState {
    phase: GamePhase
    score: i32
    lives: i32
}

fn update(gs: *GameState, pad: joypad_status_t) {
    match gs.phase {
        .title => {
            if pad.pressed.start {
                gs.phase = GamePhase.playing
                gs.score = 0
                gs.lives = 3
            }
        }
        .playing => {
            if pad.pressed.start {
                gs.phase = GamePhase.paused
            }
            -- game logic here
            if gs.lives <= 0 {
                gs.phase = GamePhase.game_over
            }
        }
        .paused => {
            if pad.pressed.start {
                gs.phase = GamePhase.playing
            }
        }
        .game_over => {
            if pad.pressed.start {
                gs.phase = GamePhase.title
            }
        }
    }
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
        {
            "instruction": (
                "Write a Pak DMA loading function that transfers data from "
                "ROM to an aligned buffer, following all required cache "
                "coherency steps."
            ),
            "output": """\
use n64.dma
use n64.cache

const DATA_SIZE: i32 = 4096
const ROM_ADDR: u32 = 0x10040000

@aligned(16)
static data_buf: [4096]u8 = undefined

fn load_from_rom() {
    cache.writeback(&data_buf[0], 4096)
    dma.read(&data_buf[0], ROM_ADDR, 4096)
    dma.wait()
    cache.invalidate(&data_buf[0], 4096)
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
        {
            "instruction": (
                "Write a Pak program that saves and loads a high score "
                "using EEPROM, with proper presence checking and 8-byte "
                "block serialization."
            ),
            "output": """\
use n64.eeprom

const SAVE_MAGIC: u32 = 0xDEAD1234
const SAVE_BLOCK: i32 = 0

@aligned(8)
static save_raw: [8]u8 = undefined

fn save_score(score: i32) {
    if not eeprom.present() { return }
    save_raw[0] = (SAVE_MAGIC >> 24) as u8
    save_raw[1] = (SAVE_MAGIC >> 16) as u8
    save_raw[2] = (SAVE_MAGIC >> 8) as u8
    save_raw[3] = SAVE_MAGIC as u8
    save_raw[4] = (score >> 24) as u8
    save_raw[5] = (score >> 16) as u8
    save_raw[6] = (score >> 8) as u8
    save_raw[7] = score as u8
    eeprom.write(SAVE_BLOCK, &save_raw[0])
}

fn load_score() -> i32 {
    if not eeprom.present() { return 0 }
    eeprom.read(SAVE_BLOCK, &save_raw[0])
    let magic: u32 = (save_raw[0] as u32 << 24)
                   | (save_raw[1] as u32 << 16)
                   | (save_raw[2] as u32 << 8)
                   | save_raw[3] as u32
    if magic != SAVE_MAGIC { return 0 }
    return (save_raw[4] as i32 << 24)
         | (save_raw[5] as i32 << 16)
         | (save_raw[6] as i32 << 8)
         | save_raw[7] as i32
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
        {
            "instruction": (
                "Write a Pak program that renders a sprite with a solid "
                "color background, demonstrating the correct RDP mode "
                "switching with sync_pipe."
            ),
            "output": """\
use n64.display
use n64.rdpq
use n64.sprite

asset player_sprite: Sprite from "sprites/player.png"

fn render(px: i32, py: i32) {
    let fb = display.get()
    rdpq.attach_clear(fb)

    rdpq.set_mode_fill(0x1A1A2EFF)
    rdpq.fill_rectangle(0, 0, 320, 240)

    rdpq.sync_pipe()
    rdpq.set_mode_copy()
    sprite.blit(player_sprite, px, py, 0)

    rdpq.detach_show()
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
        {
            "instruction": (
                "Write a basic 3D scene in Pak using tiny3d (t3d) that loads "
                "a model, sets up a viewport with projection, adds lighting, "
                "and renders it in a loop."
            ),
            "output": """\
use n64.display
use n64.controller
use n64.rdpq
use n64.timer
use t3d

entry {
    display.init(0, 2, 3, 0, 1)
    rdpq.init()
    controller.init()
    timer.init()
    t3d.init()

    let vp: T3DViewport = t3d.viewport_create()
    t3d.viewport_set_projection(&vp, 70.0, 1.0, 100.0)

    let model: *T3DModel = t3d.model_load("models/cube.t3dm")

    let mat: T3DMat4 = undefined
    t3d.mat4_identity(&mat)

    t3d.light_set_ambient(80, 80, 80)
    t3d.light_set_directional(0, 255, 255, 255, 0.0, -1.0, 0.0)
    t3d.light_set_count(1)

    let angle: f32 = 0.0

    loop {
        let dt: f32 = timer.delta()
        angle = angle + dt * 1.0

        controller.poll()
        let pad = controller.read(0)

        t3d.mat4_identity(&mat)
        t3d.mat4_rotate_y(&mat, angle)
        t3d.mat4_translate(&mat, 0.0, 0.0, -10.0)

        let fb = display.get()
        rdpq.attach_clear(fb)

        t3d.frame_start()
        t3d.viewport_attach(&vp)
        t3d.model_draw(model)
        t3d.frame_end()

        rdpq.detach_show()
    }
}""",
            "source": "handcrafted",
            "category": "cross_cutting",
        },
    ]


def validate_pak_outputs(pairs: list[dict]) -> tuple[int, int]:
    """Optionally validate Pak code blocks with pak check."""
    pak_bin = REPO_ROOT / "tools" / "validate_pak.sh"
    if not pak_bin.exists():
        print("NOTE: validate_pak.sh not found, skipping validation")
        return 0, 0

    passed, failed = 0, 0
    for pair in pairs:
        output = pair["output"]
        # Only validate if it looks like a full Pak program (not markdown)
        if "```" in output or output.startswith("In Pak") or "|" in output[:50]:
            continue

        if "entry {" in output or "fn " in output or "struct " in output:
            # Write to temp file and validate
            tmp = REPO_ROOT / ".tmp_validate.pak"
            tmp.write_text(output, encoding="utf-8")
            try:
                result = subprocess.run(
                    [str(pak_bin), str(tmp)],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                if result.returncode == 0:
                    passed += 1
                else:
                    failed += 1
                    print(f"  FAIL [{pair['source']}]: {pair['instruction'][:60]}...")
                    print(f"        {result.stderr.strip()[:200]}")
            except (subprocess.TimeoutExpired, FileNotFoundError):
                pass
            finally:
                tmp.unlink(missing_ok=True)

    return passed, failed


def main():
    validate = "--validate" in sys.argv

    print("=== Pak AI Training Data Generator ===\n")

    all_pairs = []

    generators = [
        ("Canonical Examples", gen_canonical_examples),
        ("Language Syntax", gen_language_syntax),
        ("Standard Library API", gen_stdlib_api),
        ("N64 Hardware Knowledge", gen_hardware_knowledge),
        ("Idiomatic Patterns", gen_idiom_patterns),
        ("Negative Examples (What NOT to Do)", gen_negative_examples),
        ("Cross-Cutting Examples", gen_cross_cutting),
    ]

    for name, gen_fn in generators:
        pairs = gen_fn()
        all_pairs.extend(pairs)
        print(f"  {name}: {len(pairs)} pairs")

    print(f"\nTotal: {len(all_pairs)} training pairs")

    # Category breakdown
    categories = {}
    for p in all_pairs:
        cat = p.get("category", "unknown")
        categories[cat] = categories.get(cat, 0) + 1
    print("\nBy category:")
    for cat, count in sorted(categories.items()):
        print(f"  {cat}: {count}")

    # Validation
    if validate:
        print("\nValidating Pak outputs with pak check...")
        passed, failed = validate_pak_outputs(all_pairs)
        print(f"  Passed: {passed}, Failed: {failed}")

    # Write output
    DATASET_DIR.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        for pair in all_pairs:
            # Output format: instruction/output (standard for fine-tuning)
            f.write(json.dumps({
                "instruction": pair["instruction"],
                "output": pair["output"],
                "source": pair.get("source", ""),
                "category": pair.get("category", ""),
            }, ensure_ascii=False) + "\n")

    print(f"\nDataset written to: {OUTPUT_FILE}")
    print(f"File size: {OUTPUT_FILE.stat().st_size / 1024:.1f} KB")
    print(
        f"\nThis is the SEED dataset. To reach the recommended 2000-3000 pairs,\n"
        f"you should:\n"
        f"  1. Run this script to generate the seed\n"
        f"  2. Manually write additional task-specific pairs\n"
        f"  3. Generate synthetic variations (rephrase, combine features)\n"
        f"  4. Validate ALL Pak code with: python3 {__file__} --validate\n"
    )


if __name__ == "__main__":
    main()
