#!/bin/bash
# Build only (no run)

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WhisperM8"

echo "🔨 Building $APP_NAME..."
cd "$PROJECT_DIR"
xcodebuild -scheme "$APP_NAME" -configuration Debug build -quiet

echo "✅ Build complete"
