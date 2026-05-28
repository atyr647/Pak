"""Load hand-crafted .pak game files and generate training pairs from them."""

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
GAMES_DIR = REPO_ROOT / "ai" / "dataset" / "games"

# Map filename to natural instruction
GAME_DESCRIPTIONS = {
    "pong": "Write a Pong game in Pak with two paddles, a bouncing ball, AI opponent, and score tracking.",
    "snake": "Write a Snake game in Pak with growing snake, food pickup, wrapping movement, and game over on self-collision.",
    "breakout": "Write a Breakout/Arkanoid game in Pak with paddle, bouncing ball, and destructible bricks.",
    "platformer": "Write a basic platformer in Pak with gravity, jumping, platform collision, and analog stick movement using fixed-point physics.",
    "starfield": "Write an animated starfield effect in Pak with parallax layers of different speed and brightness.",
    "shooter": "Write a top-down shooter in Pak with player movement, firing projectiles, spawning enemies, and collision detection using object pools.",
    "t3d_scene": "Write a 3D scene in Pak using tiny3d with model loading, viewport, lighting, skeleton animation, and camera controls.",
    "menu_system": "Write a menu system in Pak with cursor navigation, screen transitions between title/options/game, and controller input.",
    "audio_player": "Write an audio synthesis demo in Pak that generates tones with controller-selectable frequency and volume visualization.",
    "save_system": "Write a complete save/load system in Pak using EEPROM with magic number validation, checksum, and rumble feedback.",
    "dma_loader": "Write a DMA data loader in Pak that loads header, level, and tile data from ROM with proper cache management and @aligned buffers.",
}

# Variant instructions for each game (rephrasings)
GAME_VARIANTS = {
    "pong": [
        "Create a two-player Pong game for N64 using Pak.",
        "How would I implement Pong on N64 with Pak?",
    ],
    "snake": [
        "Implement the classic Snake game for N64 in Pak.",
        "Write a Snake clone that wraps around the screen edges in Pak.",
    ],
    "breakout": [
        "Create a brick-breaking game for N64 in Pak.",
        "Implement Arkanoid-style gameplay in Pak with colored rows of bricks.",
    ],
    "platformer": [
        "Write a side-scrolling platformer with jumping mechanics in Pak.",
        "Create a platformer with gravity and collision detection in Pak.",
    ],
    "shooter": [
        "Write a space invaders style shooter in Pak for N64.",
        "Create a top-down shoot-em-up with enemy spawning in Pak.",
    ],
    "t3d_scene": [
        "Set up a basic 3D rendering scene with tiny3d in Pak.",
        "Write a Pak program that loads and animates a 3D model using t3d.",
    ],
    "menu_system": [
        "Write a game menu with cursor navigation and screen transitions in Pak.",
        "Create a title screen with selectable options in Pak for N64.",
    ],
    "audio_player": [
        "Write a sound synthesizer demo for N64 in Pak.",
        "Create a program that generates audio tones controlled by the N64 controller in Pak.",
    ],
    "save_system": [
        "Implement persistent save data using EEPROM in Pak.",
        "Write a high score save system for N64 using Pak's EEPROM module.",
    ],
    "dma_loader": [
        "Write a ROM data loader using DMA in Pak.",
        "Show how to load game assets from cartridge ROM using DMA in Pak.",
    ],
}


def gen_game_examples() -> list[dict]:
    pairs = []

    if not GAMES_DIR.exists():
        print(f"WARNING: {GAMES_DIR} not found")
        return pairs

    for pak_file in sorted(GAMES_DIR.glob("*.pak")):
        name = pak_file.stem
        code = pak_file.read_text(encoding="utf-8").strip()

        if name not in GAME_DESCRIPTIONS:
            # Fallback: generate description from filename
            desc = f"Write a Pak program: {name.replace('_', ' ')}"
        else:
            desc = GAME_DESCRIPTIONS[name]

        # Primary pair
        pairs.append({
            "instruction": desc,
            "output": code,
            "source": f"games/{pak_file.name}",
            "category": "full_program",
        })

        # Explanation pair
        pairs.append({
            "instruction": f"Explain this Pak game program:\n\n```pak\n{code[:500]}...\n```",
            "output": f"This is a {name.replace('_', ' ')} implementation in Pak for N64. "
                      f"It uses libdragon's display, controller, and rdpq modules. "
                      f"The program follows the standard Pak game loop pattern: "
                      f"init subsystems, then loop with poll → update → render.",
            "source": f"games/{pak_file.name}",
            "category": "explanation",
        })

        # Variant instructions (same output, different phrasing)
        if name in GAME_VARIANTS:
            for variant_inst in GAME_VARIANTS[name]:
                pairs.append({
                    "instruction": variant_inst,
                    "output": code,
                    "source": f"games/{pak_file.name}",
                    "category": "full_program",
                })

        # "Modify this game" pairs
        if "struct" in code and "GameState" in code or "Game" in code:
            pairs.append({
                "instruction": f"Add a pause feature to this {name.replace('_', ' ')} game "
                               f"that toggles when Start is pressed.",
                "output": f"Add a `paused: bool` field to the game state struct, "
                          f"toggle it on `pad.pressed.start`, and skip the update logic "
                          f"when paused:\n\n"
                          f"```pak\nif pad.pressed.start {{\n    gs.paused = not gs.paused\n}}\n"
                          f"if gs.paused {{ return }}\n```",
                "source": f"games/{pak_file.name}",
                "category": "modification",
            })

    return pairs
