#!/bin/bash
set -euo pipefail

LAMBDA_FILE="dmarc_trigger.py"
ZIP_FILE="dmarc_trigger.zip"
TMP_DIR="lambda_pkg_tmp"

cd "$(dirname "$0")"

# Remove old zip if exists
rm -f "$ZIP_FILE"

if [ -f requirements.txt ]; then
  echo "requirements.txt found, installing dependencies..."
  rm -rf "$TMP_DIR"
  mkdir "$TMP_DIR"
  pip install --target "$TMP_DIR" -r requirements.txt
  cp "$LAMBDA_FILE" "$TMP_DIR/"
  (cd "$TMP_DIR" && zip -r "../$ZIP_FILE" .)
  rm -rf "$TMP_DIR"
else
  echo "No requirements.txt, packaging only $LAMBDA_FILE..."
  zip "$ZIP_FILE" "$LAMBDA_FILE"
fi

echo "Created $ZIP_FILE with contents:"
unzip -l "$ZIP_FILE" 