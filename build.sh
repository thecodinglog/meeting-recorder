#!/bin/bash
# 릴리스 빌드 후 build/MeetingRecorder.app 으로 묶는다.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/MeetingRecorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MeetingRecorder" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp diarize/diarize.py "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"

# ad-hoc 서명은 빌드마다 바뀌어 녹음 권한이 풀리므로, 개발 인증서가 있으면 그것으로 서명한다.
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}' || true)
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

echo "완료: $APP"
