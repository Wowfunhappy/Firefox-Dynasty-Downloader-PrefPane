#!/bin/bash

TITLE="Firefox Dynasty Downloader"
ICON_LABEL="Firefox \nDownloader"
BUNDLE_IDENTIFIER="Wowfunhappy.FF-Dynasty-Downloader"
OUTPUT_DIR="${TITLE}.prefPane"

# Create necessary directories
mkdir -p "${OUTPUT_DIR}/Contents/MacOS"
mkdir -p "${OUTPUT_DIR}/Contents/Resources"

defaults write "$(pwd)/Info.plist" CFBundleExecutable "$TITLE"
defaults write "$(pwd)/Info.plist" CFBundleIdentifier "$BUNDLE_IDENTIFIER"
defaults write "$(pwd)/Info.plist" CFBundleInfoDictionaryVersion "6.0"
defaults write "$(pwd)/Info.plist" CFBundleName "$TITLE"
defaults write "$(pwd)/Info.plist" CFBundlePackageType "BNDL"
defaults write "$(pwd)/Info.plist" CFBundleShortVersionString $(date +"%Y.%m.%d")
defaults write "$(pwd)/Info.plist" NSPrefPaneIconFile "icon.png"
defaults write "$(pwd)/Info.plist" NSPrefPaneIconLabel "$ICON_LABEL"

export MACOSX_DEPLOYMENT_TARGET=10.6

clang FirefoxModifier.m -dynamiclib -framework AppKit -framework Foundation ZKSwizzle.m -o Resources/FirefoxModifier.dylib

cp Info.plist "${OUTPUT_DIR}/Contents/"
cp -R Resources "${OUTPUT_DIR}/Contents/"
cp -R libs "${OUTPUT_DIR}/Contents/"

# Compile the Objective-C code
clang -framework Cocoa -framework PreferencePanes -o "${OUTPUT_DIR}/Contents/MacOS/${TITLE}" -arch x86_64 -arch i386 -bundle "PrefPane.m"

chmod -R 755 "Firefox Dynasty Downloader.prefPane"
echo "Build complete. You can find the PrefPane at ${OUTPUT_DIR}"