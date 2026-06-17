#!/bin/bash
set -e

SCHEME="TranscribeMachine"
ARCHIVE="/tmp/TranscribeMachine.xcarchive"
EXPORT_DIR="/tmp/TranscribeMachine-export"

rm -rf "$ARCHIVE" "$EXPORT_DIR"

xcodebuild archive \
  -project TranscribeMachine.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions.plist

echo "Done: $EXPORT_DIR/TranscribeMachine.app"
