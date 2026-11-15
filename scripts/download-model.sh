#!/usr/bin/env bash
# Downloads a whisper.cpp ggml model into ~/.config/utter/models.
# Usage: scripts/download-model.sh [small.en|medium.en|small|medium|base.en|large-v3-turbo]
set -euo pipefail

MODEL="${1:-small.en}"
case "$MODEL" in
  tiny|tiny.en|base|base.en|small|small.en|medium|medium.en|large-v3|large-v3-turbo|large-v3-turbo-q5_0) ;;
  *) echo "Unknown model '$MODEL'. Try small.en or medium.en." >&2; exit 1 ;;
esac

DIR="$HOME/.config/utter/models"
FILE="$DIR/ggml-$MODEL.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"

mkdir -p "$DIR"
if [ -s "$FILE" ]; then
  echo "Already have $FILE"
  exit 0
fi

echo "Downloading $MODEL to $FILE"
curl -L --fail --progress-bar -o "$FILE.part" "$URL"
mv "$FILE.part" "$FILE"
echo "Done. Set local_model = \"$MODEL\" in ~/.config/utter/config.toml if it is not the default."
