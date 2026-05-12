#!/bin/bash
# Compatibility wrapper for the canonical SwiftPM/Makefile build path.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WhisperM8"

echo "🔨 Building $APP_NAME..."
cd "$PROJECT_DIR"
make build

echo "✅ Build complete"
