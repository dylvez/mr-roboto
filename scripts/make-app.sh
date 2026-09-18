#!/bin/zsh
# Builds "Mr. Roboto.app" from the SwiftPM release build, signs it, and installs it.
#
#     scripts/make-app.sh            build, sign, install to ~/Applications, register with Finder
#     scripts/make-app.sh --no-install
#
# Why a script and not an Xcode project: the package stays the one source of truth and `make check`
# keeps covering everything. The .app is a thin wrapper — the release binary, the SwiftPM resource
# bundles in Contents/Resources (where their generated accessors look first), two icons and an
# Info.plist that declares the .roboto document type.
#
# Signing uses the first Apple Development identity in the keychain. A stable identity is the point:
# the keychain remembers "Always Allow" for the Anthropic key against the app's signature, and an
# ad-hoc signature changes on every build, which is what made the prompt come back each launch.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

NAME="Mr. Roboto"
APP="$ROOT/.build/app/$NAME.app"
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)

echo "building release…"
swift build -c release --product MrRobotoApp 2>&1 | tail -1
BIN="$ROOT/.build/release"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MrRobotoApp" "$APP/Contents/MacOS/MrRoboto"
for bundle in "$BIN"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Icons: an .iconset at every size macOS asks for, from the 1024 masters in Art/.
icns() {
    local source=$1 out=$2 set
    set=$(mktemp -d)/icon.iconset
    mkdir -p "$set"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$source" --out "$set/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$source" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o "$out"
}
icns "$ROOT/Art/app-icon-1024.png" "$APP/Contents/Resources/AppIcon.icns"
icns "$ROOT/Art/doc-icon-1024.png" "$APP/Contents/Resources/DocIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>           <string>com.mrroboto.app</string>
    <key>CFBundleName</key>                 <string>$NAME</string>
    <key>CFBundleDisplayName</key>          <string>$NAME</string>
    <key>CFBundleExecutable</key>           <string>MrRoboto</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>0.1</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>27.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>     <string>Mr. Roboto Song</string>
            <key>CFBundleTypeRole</key>     <string>Editor</string>
            <key>CFBundleTypeIconFile</key> <string>DocIcon</string>
            <key>LSHandlerRank</key>        <string>Owner</string>
            <key>LSTypeIsPackage</key>      <true/>
            <key>LSItemContentTypes</key>   <array><string>com.mrroboto.song</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>     <string>com.mrroboto.song</string>
            <key>UTTypeDescription</key>    <string>Mr. Roboto Song</string>
            <key>UTTypeIconFile</key>       <string>DocIcon</string>
            <key>UTTypeConformsTo</key>     <array><string>com.apple.package</string><string>public.composite-content</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>roboto</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
if [[ -n "$IDENTITY" ]]; then
    echo "signing as $IDENTITY"
    codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"
else
    echo "no Apple Development identity; signing ad hoc (the keychain will ask again after each build)"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

if (( INSTALL )); then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$NAME.app"
    cp -R "$APP" "$HOME/Applications/"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$HOME/Applications/$NAME.app"
    echo "installed: $HOME/Applications/$NAME.app"
else
    echo "built: $APP"
fi
