#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
FIXTURE_APP=/tmp/windowatlas-fixture/WindowAtlasFixture.app
mkdir -p "$FIXTURE_APP/Contents/MacOS"
xcrun swiftc -parse-as-library Tests/Fixtures/WindowFixture.swift -o "$FIXTURE_APP/Contents/MacOS/WindowAtlasFixture"
cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kaizaoji.windowatlas.fixture</string>
<key>CFBundleName</key><string>WindowAtlas QA</string>
<key>CFBundleExecutable</key><string>WindowAtlasFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$FIXTURE_APP"
echo "Built $FIXTURE_APP"
