#!/bin/bash
# Deploy ClaudeUsageWidget to /Applications

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

echo "Quitting running app..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1

echo "Building release..."
cd "$SCRIPT_DIR/ClaudeUsageWidget"
xcodebuild build -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget \
  -configuration Release -derivedDataPath build -quiet

echo "Copying to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "build/Build/Products/Release/$APP_NAME.app" /Applications/

echo "Launching..."
open "/Applications/$APP_NAME.app"

echo "Done - $APP_NAME deployed to /Applications"
