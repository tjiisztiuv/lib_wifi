#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="LibWiFiAutoLogin"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VFS_DIR="$BUILD_DIR/.vfs"
ARCH_BIN_DIR="$BUILD_DIR/.arch"
ZIP_PATH="$BUILD_DIR/${APP_NAME}-macOS-Universal.zip"

rm -rf "$APP_BUNDLE" "$ARCH_BIN_DIR" "$ZIP_PATH"
mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR" "$ARCH_BIN_DIR"

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
SWIFT_FILES=("$ROOT_DIR"/Sources/LibWiFiAutoLogin/**/*.swift)

EXTRA_FLAGS=()
CLT_SWIFT_INC="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ -f "$CLT_SWIFT_INC/module.modulemap" && -f "$CLT_SWIFT_INC/bridging.modulemap" ]]; then
  # Work around duplicate SwiftBridging modulemaps on upgraded CommandLineTools without touching system files.
  mkdir -p "$VFS_DIR"
  cat <<'EOF' > "$VFS_DIR/empty.modulemap"
// Override duplicate legacy modulemap
EOF
  cat <<EOF > "$VFS_DIR/overlay.yaml"
{
  "version": 0,
  "roots": [
    {
      "name": "$CLT_SWIFT_INC",
      "type": "directory",
      "contents": [
        {
          "name": "module.modulemap",
          "type": "file",
          "external-contents": "$VFS_DIR/empty.modulemap"
        }
      ]
    }
  ]
}
EOF
  EXTRA_FLAGS+=(-vfsoverlay "$VFS_DIR/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$VFS_DIR/overlay.yaml")
fi

FRAMEWORKS=(
  -framework AppKit
  -framework SwiftUI
  -framework WebKit
  -framework Network
  -framework CoreWLAN
  -framework CoreLocation
  -framework SystemConfiguration
  -framework Security
)

for ARCH in arm64 x86_64; do
  TARGET="${ARCH}-apple-macosx13.0"
  echo "Compiling ${#SWIFT_FILES[@]} Swift files for $TARGET..."
  swiftc \
    -O \
    -parse-as-library \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    "${EXTRA_FLAGS[@]}" \
    "${SWIFT_FILES[@]}" \
    "${FRAMEWORKS[@]}" \
    -o "$ARCH_BIN_DIR/${APP_NAME}-${ARCH}"
done

echo "Creating Universal binary (arm64 + x86_64)..."
lipo -create \
  "$ARCH_BIN_DIR/${APP_NAME}-arm64" \
  "$ARCH_BIN_DIR/${APP_NAME}-x86_64" \
  -output "$MACOS_DIR/${APP_NAME}"
rm -rf "$ARCH_BIN_DIR"

chmod +x "$MACOS_DIR/${APP_NAME}"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Ad-hoc sign so macOS Keychain, Location Services, and Gatekeeper behave cleanly.
codesign --force --deep --sign - "$APP_BUNDLE"
touch "$APP_BUNDLE"

echo "Packaging distributable zip..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Successfully built Universal app: $APP_BUNDLE"
echo "Successfully created zip archive: $ZIP_PATH"
