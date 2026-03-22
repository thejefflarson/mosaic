#!/bin/bash
# Generates Mosaic.app icon PNGs from Docs/icon-concept-a.svg
# and writes the AppIcon.appiconset Contents.json.
#
# Requirements (pick one; script auto-detects):
#   brew install librsvg     ← best quality
#   brew install imagemagick ← fallback
#   qlmanage (macOS built-in) ← last resort

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$SCRIPT_DIR/.."
SVG="$REPO/Docs/icon-concept-a.svg"
OUT="$REPO/Mosaic/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SVG" ]; then
  echo "error: SVG not found at $SVG" >&2
  exit 1
fi

mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Rendering SVG → 1024×1024 base PNG..."

if command -v rsvg-convert &>/dev/null; then
  rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TMP/base.png"
  echo "  (used rsvg-convert)"
elif command -v convert &>/dev/null; then
  convert -background none -density 144 -resize 1024x1024 "$SVG" "$TMP/base.png"
  echo "  (used ImageMagick convert)"
else
  # macOS built-in Quick Look renderer — creates <basename>.svg.png
  qlmanage -t -s 1024 -o "$TMP" "$SVG" 2>/dev/null
  QLOUT="$TMP/$(basename "$SVG").png"
  if [ ! -f "$QLOUT" ]; then
    echo "error: qlmanage failed. Install rsvg-convert: brew install librsvg" >&2
    exit 1
  fi
  mv "$QLOUT" "$TMP/base.png"
  echo "  (used qlmanage)"
fi

# Icon sizes: pixel_size → filename
declare -a SIZES=(16 32 64 128 256 512 1024)
declare -a NAMES=(
  "icon_16x16.png"
  "icon_32x32.png"
  "icon_32x32@2x.png"
  "icon_128x128.png"
  "icon_128x128@2x.png"
  "icon_256x256.png"
  "icon_256x256@2x.png"
  "icon_512x512.png"
  "icon_512x512@2x.png"
  "icon_1024x1024@2x.png"
)
# Pixel size for each name above (parallel arrays)
declare -a PX=(16 32 64 128 256 256 512 512 1024 1024)

# Each entry: "pixel_size filename"
ICON_SIZES=(
  "16   icon_16x16.png"
  "32   icon_32x32.png"
  "32   icon_16x16@2x.png"
  "64   icon_32x32@2x.png"
  "128  icon_128x128.png"
  "256  icon_128x128@2x.png"
  "256  icon_256x256.png"
  "512  icon_256x256@2x.png"
  "512  icon_512x512.png"
  "1024 icon_512x512@2x.png"
)

echo "Resizing to all icon sizes..."
for ENTRY in "${ICON_SIZES[@]}"; do
  PX_SIZE=$(echo "$ENTRY" | awk '{print $1}')
  FNAME=$(echo "$ENTRY" | awk '{print $2}')
  sips -z "$PX_SIZE" "$PX_SIZE" "$TMP/base.png" --out "$OUT/$FNAME" > /dev/null
  echo "  ${PX_SIZE}×${PX_SIZE} → $FNAME"
done

echo "Writing Contents.json..."
cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom":"mac", "scale":"1x", "size":"16x16",   "filename":"icon_16x16.png"         },
    { "idiom":"mac", "scale":"2x", "size":"16x16",   "filename":"icon_16x16@2x.png"       },
    { "idiom":"mac", "scale":"1x", "size":"32x32",   "filename":"icon_32x32.png"          },
    { "idiom":"mac", "scale":"2x", "size":"32x32",   "filename":"icon_32x32@2x.png"       },
    { "idiom":"mac", "scale":"1x", "size":"128x128", "filename":"icon_128x128.png"        },
    { "idiom":"mac", "scale":"2x", "size":"128x128", "filename":"icon_128x128@2x.png"     },
    { "idiom":"mac", "scale":"1x", "size":"256x256", "filename":"icon_256x256.png"        },
    { "idiom":"mac", "scale":"2x", "size":"256x256", "filename":"icon_256x256@2x.png"     },
    { "idiom":"mac", "scale":"1x", "size":"512x512", "filename":"icon_512x512.png"        },
    { "idiom":"mac", "scale":"2x", "size":"512x512", "filename":"icon_512x512@2x.png"     }
  ],
  "info" : { "author":"xcode", "version":1 }
}
JSON

echo ""
echo "Done. Icons written to:"
echo "  $OUT"
echo ""
echo "To use: open Mosaic.xcodeproj → Assets.xcassets → AppIcon"
echo "        (Xcode should pick up the new images automatically)"
