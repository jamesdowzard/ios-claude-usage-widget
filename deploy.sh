#!/bin/bash
# Deploy ClaudeUsageWidget to /Applications
# Usage: deploy-claude-widget [--no-build]

set -e

# Resolve symlinks to get actual script location
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ $SCRIPT_PATH != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
APP_NAME="ClaudeUsageWidget"
PROJECT_DIR="$SCRIPT_DIR/ClaudeUsageWidget"
BUILD_DIR="$PROJECT_DIR/build/Build/Products/Release"

# Parse args
SKIP_BUILD=false
[[ "$1" == "--no-build" ]] && SKIP_BUILD=true

# Quit running app
if pgrep -q "$APP_NAME"; then
  echo "Quitting $APP_NAME..."
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
  sleep 1
fi

# Build
if [ "$SKIP_BUILD" = false ]; then
  echo "Building release..."
  cd "$PROJECT_DIR"
  xcodebuild build -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget \
    -configuration Release -derivedDataPath build -quiet
  echo "Build complete."
else
  echo "Skipping build (--no-build)"
fi

# Deploy
echo "Deploying to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$BUILD_DIR/$APP_NAME.app" /Applications/

# Launch
echo "Launching $APP_NAME..."
open "/Applications/$APP_NAME.app"

echo "Done! $APP_NAME deployed and running."
