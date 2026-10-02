#!/bin/zsh
set -eu
TASK_ROOT=${0:A:h}
TASK_APP="$TASK_ROOT/build/DevShelf.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Security -framework CryptoKit \
  "$TASK_ROOT/Sources/Models.swift" "$TASK_ROOT/Sources/Organization.swift" "$TASK_ROOT/Sources/Shelf.swift" "$TASK_ROOT/Sources/ShelfState.swift" "$TASK_ROOT/Sources/ShelfViews.swift" "$TASK_ROOT/Sources/SettingsView.swift" "$TASK_ROOT/Sources/DevTools.swift" "$TASK_ROOT/Sources/DevToolsViews.swift" "$TASK_ROOT/Sources/FileBrowserViews.swift" "$TASK_ROOT/Sources/MCPServer.swift" "$TASK_ROOT/Sources/MCPConnect.swift" "$TASK_ROOT/Sources/MCPViews.swift" "$TASK_ROOT/Sources/FolderMarksViews.swift" "$TASK_ROOT/Sources/FolderWatch.swift" "$TASK_ROOT/Sources/Duplicates.swift" "$TASK_ROOT/Sources/DuplicatesView.swift" "$TASK_ROOT/Sources/FolderTree.swift" "$TASK_ROOT/Sources/DirectoryViews.swift" "$TASK_ROOT/Sources/App.swift" \
  -o "$TASK_APP/Contents/MacOS/DevShelf"
cp "$TASK_ROOT/Info.plist" "$TASK_APP/Contents/Info.plist"
if [[ -f "$TASK_ROOT/AppIcon.icns" ]]; then cp "$TASK_ROOT/AppIcon.icns" "$TASK_APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --deep --sign - "$TASK_APP"
print "Built: $TASK_APP"
