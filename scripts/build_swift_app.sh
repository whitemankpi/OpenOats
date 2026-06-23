#!/usr/bin/env bash
set -euo pipefail

# Build macOS .app for OpenOats (Swift)
# Usage:
#   ./scripts/build_swift_app.sh
#
# For CI / explicit identity:
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_swift_app.sh
#
# For smoke checks without code signing or installation:
#   SKIP_SIGN=1 SKIP_INSTALL=1 ./scripts/build_swift_app.sh
#
# For notarization:
#   APPLE_ID="name@example.com"
#   APPLE_TEAM_ID="TEAMID123"
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SWIFT_DIR="$ROOT_DIR/OpenOats"
APP_NAME="OpenOats"
BUNDLE_ID="com.openoats.app"
SKIP_SIGN="${SKIP_SIGN:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
BUNDLE_MLX_PARAKEET="${BUNDLE_MLX_PARAKEET:-1}"

echo "=== Building $APP_NAME (Swift) ==="

# Build release binary
cd "$SWIFT_DIR"
swift build -c release 2>&1
BINARY_PATH=".build/release/OpenOats"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

echo "Binary built: $BINARY_PATH"

# Create .app bundle
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/OpenOats"

# Make the SwiftPM-built executable behave like a normal app bundle by
# teaching dyld to search the app's embedded Frameworks directory.
APP_BINARY="$APP_DIR/Contents/MacOS/OpenOats"
if ! otool -l "$APP_BINARY" | grep -Fq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
  echo "Added app Frameworks rpath to executable"
fi

# Copy Info.plist
cp "$SWIFT_DIR/Sources/OpenOats/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy app icon
ICON_PATH="$SWIFT_DIR/Sources/OpenOats/Assets/AppIcon.icns"
if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "App icon copied"
fi

# Copy Sparkle framework
SPARKLE_ARTIFACT_DIR="$SWIFT_DIR/.build/artifacts/sparkle"
SPARKLE_FW=$(find "$SPARKLE_ARTIFACT_DIR" -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [[ -n "$SPARKLE_FW" ]]; then
  cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"
  echo "Sparkle.framework copied"
else
  echo "Warning: Sparkle.framework not found in build artifacts"
fi

# Copy SPM resource bundles (needed by swift-transformers for tokenizer fallback configs)
COPIED_BUNDLES=0
while IFS= read -r -d '' bundle; do
  bundle_name="$(basename "$bundle")"
  destination="$APP_DIR/Contents/Resources/$bundle_name"
  rm -rf "$destination"
  cp -R "$bundle" "$destination"
  COPIED_BUNDLES=$((COPIED_BUNDLES + 1))
done < <(find "$SWIFT_DIR/.build" -path "*/release/*.bundle" -type d -print0)
if [[ $COPIED_BUNDLES -gt 0 ]]; then
  echo "Copied $COPIED_BUNDLES SPM resource bundle(s)"
else
  echo "Warning: no SPM resource bundles found under $SWIFT_DIR/.build"
fi

# Bundle the MLX Parakeet helper so users do not need to install parakeet-mlx globally.
# Set BUNDLE_MLX_PARAKEET=0 for fast smoke builds or offline build environments.
if [[ "$BUNDLE_MLX_PARAKEET" == "1" ]]; then
  MLX_HELPER_DIR="$APP_DIR/Contents/Resources/MLXParakeet"
  rm -rf "$MLX_HELPER_DIR"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required to bundle the MLX Parakeet helper" >&2
    exit 1
  fi

  echo "Bundling MLX Parakeet helper (parakeet-mlx)"
  python3 -m venv --copies "$MLX_HELPER_DIR"
  "$MLX_HELPER_DIR/bin/python" -m pip install --upgrade pip
  "$MLX_HELPER_DIR/bin/python" -m pip install --upgrade parakeet-mlx

  if [[ ! -x "$MLX_HELPER_DIR/bin/parakeet-mlx" ]]; then
    echo "Error: parakeet-mlx helper was not installed into $MLX_HELPER_DIR/bin" >&2
    exit 1
  fi

  find "$MLX_HELPER_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +
  find "$MLX_HELPER_DIR" -type f -name "*.pyc" -delete
  echo "MLX Parakeet helper bundled at $MLX_HELPER_DIR"
else
  echo "Skipping MLX Parakeet helper bundle (BUNDLE_MLX_PARAKEET=0)"
fi

# Add PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"

if [[ "$SKIP_SIGN" == "1" ]]; then
  echo "Skipping code signing"
else
  # Auto-detect signing identity if not set
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [[ -z "$CODESIGN_IDENTITY" ]]; then
      CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    fi
  fi

  # Sign the app
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    ENTITLEMENTS="$SWIFT_DIR/Sources/OpenOats/OpenOats.entitlements"
    echo "Signing with: $CODESIGN_IDENTITY"

    # Sign Sparkle components inside-out (innermost first)
    SPARKLE_FW_BUNDLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$SPARKLE_FW_BUNDLE" ]]; then
      # Sign XPC service executables, then their bundles
      for xpc in "$SPARKLE_FW_BUNDLE"/Versions/B/XPCServices/*.xpc; do
        if [[ -d "$xpc" ]]; then
          codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$xpc/Contents/MacOS/$(basename "${xpc%.xpc}")"
          codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$xpc"
        fi
      done

      # Sign Autoupdate helper
      AUTOUPDATE="$SPARKLE_FW_BUNDLE/Versions/B/Autoupdate"
      if [[ -f "$AUTOUPDATE" ]]; then
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$AUTOUPDATE"
      fi

      # Sign Updater.app
      UPDATER_APP="$SPARKLE_FW_BUNDLE/Versions/B/Updater.app"
      if [[ -d "$UPDATER_APP" ]]; then
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$UPDATER_APP/Contents/MacOS/Updater"
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$UPDATER_APP"
      fi

      # Sign the framework dylib, then the framework bundle
      codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$SPARKLE_FW_BUNDLE/Versions/B/Sparkle"
      codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$SPARKLE_FW_BUNDLE"
    fi

    # Sign bundled MLX/Python native code before signing the app bundle.
    MLX_HELPER_DIR="$APP_DIR/Contents/Resources/MLXParakeet"
    if [[ -d "$MLX_HELPER_DIR" ]]; then
      while IFS= read -r -d '' executable; do
        if file "$executable" | grep -Eq 'Mach-O|dynamically linked shared library'; then
          codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$executable"
        fi
      done < <(find "$MLX_HELPER_DIR" -type f -perm -111 -print0)

      while IFS= read -r -d '' library; do
        if file "$library" | grep -Eq 'Mach-O|dynamically linked shared library'; then
          codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$library"
        fi
      done < <(find "$MLX_HELPER_DIR" \( -name '*.so' -o -name '*.dylib' \) -type f -print0)
    fi

    # Sign the main app bundle
    codesign --force --options runtime \
      --sign "$CODESIGN_IDENTITY" \
      --entitlements "$ENTITLEMENTS" \
      --timestamp \
      "$APP_DIR"

    echo "Code signing complete"
    codesign -vvv "$APP_DIR"
  else
    echo "Warning: No signing identity found. App will be unsigned."
  fi
fi

if [[ "$SKIP_INSTALL" == "1" ]]; then
  echo "Skipping installation to /Applications"
else
  cp -R "$APP_DIR" /Applications/
  echo "Installed to /Applications/$APP_NAME.app"
fi

echo "=== Build complete ==="
