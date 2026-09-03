# Pak N64 AI — Training Data

Instruction/output pairs for fine-tuning a code model on N64 homebrew in Pak,
libdragon and Tiny3D.

## What is here

* `dataset/seed_dataset.jsonl` — pairs mined from this repo's documentation and
  canonical examples.
* `dataset/full_dataset.jsonl` — the expanded set.
* `dataset/games/*.pk64` — complete example programs. These are part of the
  compiler's golden corpus, so they are compiled and checked on every push.
* `Modelfile` — Ollama model definition for serving a fine-tuned checkpoint.

## What is not here

The generation and training scripts were removed when Python was removed from
the repository. Fine-tuning a 7B model is not something the Pak toolchain does,
and there is no Tcl equivalent to port them to — the datasets above are the
durable artifact, and any trainer can consume them. The old scripts remain in
git history if you want them back.

## Validating dataset programs

```bash
pak check ai/dataset/games/breakout.pk64
tclsh tcl/tools/golden_test.tcl check tc   # the whole corpus, this dir included
```
