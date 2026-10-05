#!/bin/sh
# package_macos.sh [version] [--render-icon]
#
# Builds the release binary and assembles a self-contained
# builds/apple/Shader Explorer.app plus a distributable zip.
#
# The app resolves assets/, src/shaders and vendor/slang relative to the
# working directory, so the bundle mirrors the repo layout under
# Contents/Resources/app and the launcher anchors the cwd there.
#
# Icon source is assets/icon-1024.png (tracked). --render-icon re-renders
# it from the app itself (scene 8, center-cropped) before packaging.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION="0.1.0"
RENDER_ICON=0
for arg in "$@"; do
	case "$arg" in
	--render-icon) RENDER_ICON=1 ;;
	*) VERSION="$arg" ;;
	esac
done

APP_NAME="Shader Explorer"
OUT="builds/apple"
BUNDLE="$OUT/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
APP_RSC="$CONTENTS/Resources/app"
ICON_SRC="assets/icon-1024.png"
GOOSE_DIR="${GOOSE_DIR:-../goose}"
ARCH=$(uname -m)
ZIP="shader-explorer-$VERSION-macos-$ARCH.zip"

# 1. Shader glue and vendored static libs (no-op when fresh).
make shaders vendor/ImGuiColorTextEdit/libite.a vendor/imnodes/libine.a

# 2. Release binary (same flags as `make build`).
mkdir -p "$OUT"
odin build ./src -out:"$OUT/shader_explorer" \
	-o:aggressive -microarch:native -no-bounds-check -disable-assert

# 3. Optional: re-render the icon from the app itself. The shot is the
#    800x600 frame; the center 600x600 crop drops the axes gizmo.
if [ "$RENDER_ICON" = 1 ]; then
	"$OUT/shader_explorer" --scene 8 --shot /tmp/se_icon_shot.png
	sips -c 600 600 /tmp/se_icon_shot.png --out /tmp/se_icon_sq.png >/dev/null
	sips -z 1024 1024 /tmp/se_icon_sq.png --out "$ICON_SRC" >/dev/null
	echo "icon: re-rendered $ICON_SRC"
fi

# 4. Bundle skeleton + payload. Writable dirs: the runtime generates scene
#    artifacts (src/generated/scenes) and exports screenshots (exports).
rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$APP_RSC/src/generated/scenes" "$APP_RSC/exports" \
	"$APP_RSC/vendor/fonts" "$APP_RSC/vendor/slang"
cp "$OUT/shader_explorer" "$APP_RSC/"
cp "$GOOSE_DIR/goose-build" "$APP_RSC/"
rsync -a --exclude image.png --exclude icon-1024.png --exclude .DS_Store \
	assets "$APP_RSC/"
cp -R src/shaders "$APP_RSC/src/"
cp vendor/fonts/JetBrainsMono-Regular.ttf "$APP_RSC/vendor/fonts/"
cp -R vendor/slang/bin vendor/slang/lib "$APP_RSC/vendor/slang/"

# 5. Launcher: anchors the cwd inside the bundle and points GOOSE at the
#    bundled goose-build (scenes are compiled at runtime).
cat >"$CONTENTS/MacOS/launch" <<'LAUNCH'
#!/bin/sh
cd "$(dirname "$0")/../Resources/app" || exit 1
export GOOSE="$PWD/goose-build"
exec ./shader_explorer "$@"
LAUNCH
chmod +x "$CONTENTS/MacOS/launch"

# 6. Info.plist.
cat >"$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>launch</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.gobbi.shader-explorer</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
</dict>
</plist>
EOF

# 7. Icon: full iconset from the tracked 1024px source.
if [ -f "$ICON_SRC" ]; then
	rm -rf /tmp/se_appicon.iconset
	mkdir /tmp/se_appicon.iconset
	for spec in \
		"16 icon_16x16" "32 icon_16x16@2x" \
		"32 icon_32x32" "64 icon_32x32@2x" \
		"128 icon_128x128" "256 icon_128x128@2x" \
		"256 icon_256x256" "512 icon_256x256@2x" \
		"512 icon_512x512" "1024 icon_512x512@2x"; do
		set -- $spec
		sips -z "$1" "$1" "$ICON_SRC" --out "/tmp/se_appicon.iconset/$2.png" >/dev/null
	done
	iconutil -c icns /tmp/se_appicon.iconset -o "$CONTENTS/Resources/AppIcon.icns"
else
	echo "warning: $ICON_SRC missing; bundle will have no icon" >&2
fi

# 8. Distributable zip.
rm -f "$OUT/$ZIP"
(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP")

echo "OK $BUNDLE"
echo "OK $OUT/$ZIP"
