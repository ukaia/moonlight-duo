#!/bin/bash
# Moonlight Duo: settings self-test + screenshots on a booted iPhone Duo simulator (DEBUG build).
#
#   xcodebuild -project Moonlight.xcodeproj -scheme Moonlight -configuration Debug \
#     -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
#   BuildScripts/duo_shots.sh [simulator-udid]
#
# Results: build/screenshots/*.png and build/settings-selftest.txt. Needs python3 with Pillow.
set -u
cd "$(dirname "$0")/.."
UDID=${1:-$(xcrun simctl list devices booted | sed -n 's/.*iPhone Duo (\([0-9A-F-]*\)) (Booted).*/\1/p' | head -1)}
[ -n "$UDID" ] || { echo "Boot an iPhone Duo simulator first, or pass its UDID."; exit 1; }
BID=com.moonlight-duo.Moonlight
APP=${APP:-build/DerivedData/Build/Products/Debug-iphonesimulator/Moonlight.app}
OUT=build/screenshots
mkdir -p "$OUT"; rm -f "$OUT"/*.png
xcrun simctl install $UDID "$APP" || exit 1
DATA=$(xcrun simctl get_app_container $UDID $BID data)
xcrun simctl status_bar $UDID override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 >/dev/null 2>&1

run() {  # name wait args...
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate $UDID $BID >/dev/null 2>&1
  rm -f "$DATA/Documents/harness-frame.txt"
  xcrun simctl launch $UDID $BID "$@" >/dev/null
  sleep $wait
  xcrun simctl io $UDID screenshot --display=1 "$OUT/raw-$name.png" >/dev/null 2>&1
  if [ -f "$DATA/Documents/harness-frame.txt" ]; then
    read x y w h s < "$DATA/Documents/harness-frame.txt"
    python3 - "$OUT/raw-$name.png" "$OUT/$name.png" $x $y $w $h <<'PY'
import sys
from PIL import Image
src, dst, x, y, w, h = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:])
im = Image.open(src); k = im.width / 466.0
im.crop((round(x*k), round(y*k), round((x+w)*k), round((y+h)*k))).save(dst)
PY
    rm "$OUT/raw-$name.png"
  else
    mv "$OUT/raw-$name.png" "$OUT/$name.png"
  fi
  echo "shot $name"
}

# 1. Settings self-test
xcrun simctl terminate $UDID $BID >/dev/null 2>&1
rm -f "$DATA/Documents/settings-selftest.txt"
xcrun simctl launch $UDID $BID -MLSettingsSelfTest YES >/dev/null
for i in $(seq 1 30); do [ -f "$DATA/Documents/settings-selftest.txt" ] && break; sleep 1; done
cp "$DATA/Documents/settings-selftest.txt" "$OUT/../settings-selftest.txt" 2>/dev/null
head -1 "$OUT/../settings-selftest.txt" 2>/dev/null || echo "SELFTEST: no result file"
grep "^FAIL" "$OUT/../settings-selftest.txt" 2>/dev/null

D="-MLDemo YES"
# Outer display (real simulator captures, portrait)
run 01-outer-pcs 5 $D
run 02-outer-games 5 $D -MLSelectHost demo-desk
run 03-outer-settings 6 $D -MLOpenSettings YES
run 04-outer-settings-controls 7 $D -MLOpenSettings YES -MLSettingsSection controls
run 05-outer-stream-portrait-3d 7 $D -MLSelectHost demo-desk -MLStartStream "Hades II" -MLPadLayout 1
# Harness renders (laid out at the other displays' sizes)
run 06-outer-landscape-games 6 $D -MLHarness 678x466 -MLSelectHost demo-desk
run 07-outer-landscape-stream-2d 7 $D -MLHarness 678x466 -MLSelectHost demo-desk -MLStartStream "Hades II" -MLPadLayout 0
run 08-inner-landscape-games 6 $D -MLHarness 890x626 -MLSelectHost demo-desk
run 09-inner-book-fold-games 6 $D -MLHarness 890x626 -MLSimulateFold vertical -MLDetailOnly YES -MLSelectHost demo-desk
run 10-inner-book-fold-stream-3d 7 $D -MLHarness 890x626 -MLSimulateFold vertical -MLSelectHost demo-desk -MLStartStream "Hades II" -MLPadLayout 1
run 11-inner-portrait-games 6 $D -MLHarness 626x890 -MLSelectHost demo-desk
run 12-inner-tabletop-stream-3d 7 $D -MLHarness 626x890 -MLSimulateFold horizontal -MLSelectHost demo-desk -MLStartStream "Hades II" -MLPadLayout 1
run 13-inner-landscape-stream-3d 7 $D -MLHarness 890x626 -MLSelectHost demo-desk -MLStartStream "Hades II" -MLPadLayout 1
xcrun simctl terminate $UDID $BID >/dev/null 2>&1
ls "$OUT"
