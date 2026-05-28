#!/usr/bin/env python3
"""
train.py — Fine-tune Qwen2.5-Coder 7B on Pak N64 dataset using QLoRA via Unsloth.

Requirements:
    pip install unsloth transformers datasets peft accelerate bitsandbytes

For AMD 7900XT (ROCm):
    pip install torch --index-url https://download.pytorch.org/whl/rocm6.0
    pip install unsloth

Usage:
    python3 ai/scripts/train.py                          # train with defaults
    python3 ai/scripts/train.py --epochs 5               # more epochs
    python3 ai/scripts/train.py --model-path ~/models/qwen25-coder-7b  # custom model path
    python3 ai/scripts/train.py --export-gguf             # export GGUF after training

The script will:
    1. Load the base model in 4-bit quantization (QLoRA)
    2. Apply LoRA adapters to all attention + MLP layers
    3. Train on the seed dataset
    4. Save the adapter weights
    5. Optionally merge + export to GGUF for Ollama
"""

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DATASET_PATH = REPO_ROOT / "ai" / "dataset" / "full_dataset.jsonl"
OUTPUT_DIR = REPO_ROOT / "ai" / "model_output"

# -- System prompt baked into training format --
SYSTEM_PROMPT = (
    "You are an expert N64 homebrew developer. You write exclusively in Pak, "
    "a language that transpiles to C targeting libdragon and tiny3d. You follow "
    "all Pak syntax rules: entry {} not main(), 'and'/'or'/'not' for logic, "
    "'none' not null, explicit casts with 'as', no semicolons. You understand "
    "N64 hardware constraints including DMA alignment, cache coherency, TMEM "
    "limits, controller polling order, and EEPROM block sizes. You never invent "
    "APIs not in the Pak standard library."
)


def format_prompt(instruction: str, output: str = "") -> str:
    """Format a single training example in ChatML format (Qwen's native format)."""
    text = (
        f"<|im_start|>system\n{SYSTEM_PROMPT}<|im_end|>\n"
        f"<|im_start|>user\n{instruction}<|im_end|>\n"
        f"<|im_start|>assistant\n{output}<|im_end|>"
    )
    return text


def load_dataset(path: Path) -> list[dict]:
    """Load JSONL dataset."""
    if not path.exists():
        print(f"ERROR: Dataset not found at {path}")
        print(f"Run prepare_data.py first: python3 ai/scripts/prepare_data.py")
        sys.exit(1)

    pairs = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                pairs.append(json.loads(line))

    print(f"Loaded {len(pairs)} training pairs from {path}")
    return pairs


def main():
    parser = argparse.ArgumentParser(description="Fine-tune Qwen2.5-Coder 7B for Pak")
    parser.add_argument(
        "--model-path",
        default="Qwen/Qwen2.5-Coder-7B",
        help="HuggingFace model ID or local path (default: Qwen/Qwen2.5-Coder-7B)",
    )
    parser.add_argument(
        "--dataset",
        type=Path,
        default=DATASET_PATH,
        help="Path to training JSONL file",
    )
    parser.add_argument("--epochs", type=int, default=3, help="Number of training epochs")
    parser.add_argument("--batch-size", type=int, default=2, help="Per-device batch size")
    parser.add_argument("--grad-accum", type=int, default=4, help="Gradient accumulation steps")
    parser.add_argument("--lr", type=float, default=2e-4, help="Learning rate")
    parser.add_argument("--lora-rank", type=int, default=128, help="LoRA rank (higher = more capacity)")
    parser.add_argument("--lora-alpha", type=int, default=64, help="LoRA alpha")
    parser.add_argument("--max-seq-len", type=int, default=4096, help="Maximum sequence length")
    parser.add_argument("--export-gguf", action="store_true", help="Export merged GGUF after training")
    parser.add_argument(
        "--gguf-quant",
        default="q5_k_m",
        choices=["q4_k_m", "q5_k_m", "q6_k", "q8_0", "f16"],
        help="GGUF quantization method (default: q5_k_m)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print config and exit without training")
    args = parser.parse_args()

    print("=" * 60)
    print("Pak N64 AI — Fine-Tuning with Unsloth + QLoRA")
    print("=" * 60)
    print(f"  Base model:     {args.model_path}")
    print(f"  Dataset:        {args.dataset}")
    print(f"  Epochs:         {args.epochs}")
    print(f"  Batch size:     {args.batch_size} (x{args.grad_accum} grad accum)")
    print(f"  Effective batch: {args.batch_size * args.grad_accum}")
    print(f"  Learning rate:  {args.lr}")
    print(f"  LoRA rank:      {args.lora_rank}")
    print(f"  LoRA alpha:     {args.lora_alpha}")
    print(f"  Max seq length: {args.max_seq_len}")
    print(f"  Export GGUF:    {args.export_gguf} ({args.gguf_quant})")
    print()

    # Load and preview dataset
    raw_data = load_dataset(args.dataset)

    if args.dry_run:
        print("\n[DRY RUN] Would train on the above config. Exiting.")
        print("\nSample formatted prompt:")
        print("-" * 40)
        print(format_prompt(raw_data[0]["instruction"], raw_data[0]["output"])[:500])
        print("...")
        return

    # ---------------------------------------------------------------
    # Import heavy dependencies only when actually training
    # ---------------------------------------------------------------
    try:
        from unsloth import FastLanguageModel
    except ImportError:
        print("ERROR: unsloth not installed.")
        print("Install with: pip install unsloth")
        print("For AMD ROCm: pip install torch --index-url https://download.pytorch.org/whl/rocm6.0")
        sys.exit(1)

    from datasets import Dataset
    from transformers import TrainingArguments
    from trl import SFTTrainer

    # ---------------------------------------------------------------
    # 1. Load base model in 4-bit (QLoRA)
    # ---------------------------------------------------------------
    print("\n[1/5] Loading base model...")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.model_path,
        max_seq_length=args.max_seq_len,
        load_in_4bit=True,
        dtype=None,  # auto-detect
    )

    # ---------------------------------------------------------------
    # 2. Apply LoRA adapters
    # ---------------------------------------------------------------
    print("[2/5] Applying LoRA adapters...")
    model = FastLanguageModel.get_peft_model(
        model,
        r=args.lora_rank,
        lora_alpha=args.lora_alpha,
        lora_dropout=0.05,
        target_modules=[
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ],
        bias="none",
        use_gradient_checkpointing="unsloth",
        random_state=42,
    )

    # ---------------------------------------------------------------
    # 3. Prepare dataset
    # ---------------------------------------------------------------
    print("[3/5] Preparing dataset...")
    formatted = [
        {"text": format_prompt(d["instruction"], d["output"])}
        for d in raw_data
    ]
    dataset = Dataset.from_list(formatted)

    # ---------------------------------------------------------------
    # 4. Train
    # ---------------------------------------------------------------
    print("[4/5] Starting training...")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    training_args = TrainingArguments(
        output_dir=str(OUTPUT_DIR / "checkpoints"),
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        weight_decay=0.01,
        warmup_ratio=0.1,
        lr_scheduler_type="cosine",
        logging_steps=5,
        save_strategy="epoch",
        bf16=True,
        optim="adamw_8bit",
        seed=42,
        report_to="none",
    )

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset,
        dataset_text_field="text",
        max_seq_length=args.max_seq_len,
        args=training_args,
    )

    trainer.train()

    # Save adapter
    adapter_path = OUTPUT_DIR / "pak_coder_lora"
    model.save_pretrained(str(adapter_path))
    tokenizer.save_pretrained(str(adapter_path))
    print(f"\nAdapter saved to: {adapter_path}")

    # ---------------------------------------------------------------
    # 5. Optional: export merged GGUF
    # ---------------------------------------------------------------
    if args.export_gguf:
        print(f"[5/5] Exporting merged GGUF ({args.gguf_quant})...")
        gguf_path = OUTPUT_DIR / f"pak-coder-7b-{args.gguf_quant.upper()}.gguf"
        model.save_pretrained_gguf(
            str(OUTPUT_DIR / "pak-coder-7b"),
            tokenizer,
            quantization_method=args.gguf_quant,
        )
        print(f"GGUF exported to: {OUTPUT_DIR}/pak-coder-7b/")
        print(f"\nTo load in Ollama:")
        print(f"  1. Copy the .gguf file to your Ollama models directory")
        print(f"  2. Create a Modelfile (see ai/Modelfile)")
        print(f"  3. Run: ollama create pak-coder -f ai/Modelfile")
        print(f"  4. Run: ollama run pak-coder")
    else:
        print("[5/5] Skipping GGUF export (use --export-gguf to enable)")

    print("\n" + "=" * 60)
    print("Training complete!")
    print("=" * 60)


if __name__ == "__main__":
    main()
