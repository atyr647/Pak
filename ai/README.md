# Pak N64 AI — Fine-Tuned Code Model

Fine-tuning pipeline for building a **Qwen2.5-Coder 7B** model specialized
exclusively in N64 homebrew development using Pak, libdragon, and tiny3d.

## Quick Start

### 1. Generate training data

```bash
python3 ai/scripts/prepare_data.py
```

This mines the repo's documentation and canonical examples to produce a seed
dataset at `ai/dataset/seed_dataset.jsonl` (~150 pairs). You should expand this
to **2000–3000 pairs** by:

- Writing additional instruction/output pairs manually
- Generating synthetic variations (rephrase prompts, combine features)
- Adding libdragon C examples and Pak↔C comparison pairs
- Adding t3d-specific 3D rendering examples

Validate all Pak code in the dataset:

```bash
python3 ai/scripts/prepare_data.py --validate
```

### 2. Install dependencies

```bash
# For AMD 7900XT (ROCm)
pip install torch --index-url https://download.pytorch.org/whl/rocm6.0
pip install -r ai/scripts/requirements.txt
```

### 3. Download base model

```bash
pip install huggingface-hub
huggingface-cli download Qwen/Qwen2.5-Coder-7B --local-dir ~/models/qwen25-coder-7b
```

### 4. Fine-tune

```bash
# Dry run (check config without training)
python3 ai/scripts/train.py --dry-run

# Train with defaults (3 epochs, LoRA rank 128)
python3 ai/scripts/train.py --model-path ~/models/qwen25-coder-7b

# Train + export GGUF for Ollama
python3 ai/scripts/train.py --model-path ~/models/qwen25-coder-7b --export-gguf

# More aggressive specialization
python3 ai/scripts/train.py --model-path ~/models/qwen25-coder-7b --epochs 5 --lora-rank 128 --export-gguf
```

### 5. Load in Ollama

```bash
# Update the FROM path in ai/Modelfile to point to your exported .gguf
ollama create pak-coder -f ai/Modelfile
ollama run pak-coder
```

### 6. Evaluate

```bash
python3 ai/scripts/evaluate.py --model pak-coder
python3 ai/scripts/evaluate.py --model pak-coder --verbose --output results.json
```

## Directory Structure

```
ai/
├── README.md              # This file
├── Modelfile              # Ollama model configuration
├── dataset/
│   └── seed_dataset.jsonl # Auto-generated seed training data
├── scripts/
│   ├── prepare_data.py    # Extract training pairs from repo docs
│   ├── train.py           # QLoRA fine-tuning via Unsloth
│   ├── evaluate.py        # Benchmark model against test tasks
│   └── requirements.txt   # Python dependencies
└── model_output/          # (created during training, gitignored)
    ├── checkpoints/       # Training checkpoints
    └── pak_coder_lora/    # Saved LoRA adapter
```

## Model Details

| Parameter | Value |
|-----------|-------|
| Base model | Qwen2.5-Coder 7B |
| Quantization | QLoRA (4-bit base, LoRA adapters) |
| LoRA rank | 128 |
| LoRA targets | q/k/v/o_proj, gate/up/down_proj |
| Export quant | Q5_K_M (recommended for 7900XT) |
| VRAM usage | ~6 GB inference, ~16 GB training |
| Context length | 4096 tokens |

## Training Data Categories

| Category | Description | Seed Count |
|----------|-------------|------------|
| full_program | Complete .pak programs from canonical examples | 22 |
| explanation | "Explain this code" reverse pairs | 22 |
| syntax | Language syntax Q&A from LANGUAGE.md | 15 |
| api_reference | Module API docs from STDLIB.md | 14 |
| api_usage | Module usage examples from STDLIB.md | 14 |
| hardware | N64 hardware knowledge from N64_HARDWARE.md | 11 |
| idiom | Idiomatic patterns from IDIOMS.md | 17 |
| negative | "What NOT to do" from NOT_SUPPORTED.md | 27 |
| cross_cutting | Hand-crafted multi-domain examples | 8 |

## Expanding the Dataset

The seed dataset is a starting point. To build a production-quality model:

1. **Write full game examples** — Complete mini-games (Pong, Snake, platformer)
   as instruction/output pairs
2. **Add debugging pairs** — "This code has bug X, fix it" with before/after
3. **Add libdragon C knowledge** — C examples from libdragon's own examples/
4. **Add t3d deep knowledge** — Model loading, animation, camera, lighting pairs
5. **Add hardware edge cases** — TMEM limits, texture format constraints,
   Z-buffer gotchas, audio buffer sizing
6. **Validate everything** — Every Pak output must pass `pak check`
