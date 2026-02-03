#!/bin/bash
# Kill all WhisperM8 instances

APP_NAME="WhisperM8"

if pkill -f "$APP_NAME" 2>/dev/null; then
    echo "✅ Killed all $APP_NAME instances"
else
    echo "ℹ️  No $APP_NAME instances running"
fi
