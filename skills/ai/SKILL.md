---
name: ai
description: >-
  Switch the chat model routing between the default rotating pool
  (NVIDIA + Mistral) and OpenRouter-only mode, check routing status, or
  list available OpenRouter free models. Use when the boss sends /ai or
  "ai" commands like: ai status, ai pool, ai or <model-id>, ai models.
---

# AI Route Switcher

Everything goes through the preinstalled `ai` terminal command
(`~/.local/bin/ai`). Run it and reply with its EXACT output — do not
paraphrase, summarize, or add extra commentary.

## Procedure

1. Take the arguments after the skill name exactly as given.
   - `/ai status` or `ai status`  -> run `ai status`
   - `/ai pool`                   -> run `ai pool`
   - `/ai or <model-id>`          -> run `ai or <model-id>`
   - `/ai or`                     -> run `ai or`
   - `/ai models`                 -> run `ai models`
   - `/ai` with no args           -> run `ai status`
2. Run the command in the terminal, e.g. `ai or deepseek/deepseek-chat:free`.
3. Reply with the command's exact stdout. Nothing else.

## Command reference

- `ai status` / `ai st`  — show current mode (pool or openrouter) and model
- `ai pool` / `ai default` / `ai off` — switch chat back to the rotating
  NVIDIA + Mistral pool (default mode)
- `ai or <model-id>` — switch chat to OpenRouter ONLY, locked to that model
- `ai or` — switch to OpenRouter ONLY using the panel-ticked OpenRouter models
- `ai models` / `ai list` — list OpenRouter models ticked in the panel

## Rules (strict separation)

- Pool mode uses ONLY NVIDIA + Mistral. OpenRouter mode uses ONLY
  OpenRouter. They are never mixed; there is no cross-provider fallback.
- NEVER edit `~/.hermes/route_mode` or `~/.hermes/openrouter_model` by
  hand — always go through the `ai` command.
- If `ai` is not found, tell the boss the ai CLI is missing from
  ~/.local/bin (workflow install step failed) — do not improvise.

## Verification

`ai status` reflects the new mode immediately after a switch.
