#!/bin/bash
# Build, kill old instances, run new build

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WhisperM8"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

# Find the DerivedData folder for this project
BUILD_DIR=$(find "$DERIVED_DATA" -maxdepth 1 -name "${APP_NAME}-*" -type d 2>/dev/null | head -1)

if [ -z "$BUILD_DIR" ]; then
    echo "⚠️  No existing build found. Building fresh..."
fi

echo "🔨 Building $APP_NAME..."
cd "$PROJECT_DIR"
xcodebuild -scheme "$APP_NAME" -configuration Debug build -quiet

# Re-find build dir after build (in case it was just created)
BUILD_DIR=$(find "$DERIVED_DATA" -maxdepth 1 -name "${APP_NAME}-*" -type d 2>/dev/null | head -1)

if [ -z "$BUILD_DIR" ]; then
    echo "❌ Build directory not found!"
    exit 1
fi

APP_PATH="$BUILD_DIR/Build/Products/Debug/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at: $APP_PATH"
    exit 1
fi

echo "🔪 Killing existing instances..."
pkill -f "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "🚀 Starting $APP_NAME..."
open "$APP_PATH"

echo "✅ Done - $APP_NAME is running"
