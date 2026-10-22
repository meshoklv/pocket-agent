#!/usr/bin/env bash
# Download the default model (Gemma 4 E2B, LiteRT-LM, ~2 GB) from Hugging Face
# and verify its SHA-256. Revision, size and hash match PocketAgent/Runtime/ModelCatalog.swift.
# Usage: scripts/download-model.sh [output-dir]   (default: ./models)
# Then copy the file to the iPhone (Files app -> Pocket Agent) - see README.
# Check the model's license on its Hugging Face page before redistributing.
set -euo pipefail
OUT="${1:-models}"
REPO="litert-community/gemma-4-E2B-it-litert-lm"
REV="6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94"
FILE="gemma-4-E2B-it-gpu.litertlm"
SHA="a53a59001894c58e6bdb5b9b227709f91a2e3e556baa7d85acf9c55402ba5cf5"
mkdir -p "$OUT"
curl -L --fail -C - -o "$OUT/$FILE" "https://huggingface.co/$REPO/resolve/$REV/$FILE"
if command -v sha256sum >/dev/null; then GOT=$(sha256sum "$OUT/$FILE" | cut -d' ' -f1); else GOT=$(shasum -a 256 "$OUT/$FILE" | cut -d' ' -f1); fi
[ "$GOT" = "$SHA" ] && echo "OK: $OUT/$FILE" || { echo "SHA-256 mismatch" >&2; exit 1; }
