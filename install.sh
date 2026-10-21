#!/bin/bash
set -e

echo "🚀 Installing NetPulse PRO for macOS..."

DOWNLOAD_URL="https://github.com/xElyanax/NetPulse/releases/latest/download/NetPulse.zip"
TMP_DIR=$(mktemp -d)
ZIP_PATH="$TMP_DIR/NetPulse.zip"
APP_DIR="/Applications"

echo "📥 Downloading latest NetPulse release..."
curl -fsSL -o "$ZIP_PATH" "$DOWNLOAD_URL"

echo "📦 Extracting application..."
unzip -q -o "$ZIP_PATH" -d "$TMP_DIR"

echo "🛡️ Bypassing macOS Gatekeeper quarantine..."
xattr -cr "$TMP_DIR/NetPulse.app" 2>/dev/null || true

echo "📁 Installing to /Applications..."
# Kill any currently running instance
killall NetPulse 2>/dev/null || true
rm -rf "$APP_DIR/NetPulse.app"
mv "$TMP_DIR/NetPulse.app" "$APP_DIR/NetPulse.app"

# Remove quarantine on installed destination as well
xattr -cr "$APP_DIR/NetPulse.app" 2>/dev/null || true

rm -rf "$TMP_DIR"

echo "✅ NetPulse installed successfully to $APP_DIR/NetPulse.app!"
echo "✨ Launching NetPulse..."
open "$APP_DIR/NetPulse.app"
