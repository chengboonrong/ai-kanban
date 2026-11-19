#!/bin/bash
# Renders every platform's app icon from tool/app_icon.svg with headless Chrome (CHROME=... overrides the path).
# Re-run after editing the SVG; it overwrites the icon files in place.
set -euo pipefail
cd "$(dirname "$0")/.."
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
mark="file://$PWD/tool/app_icon.svg"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
shell='#E6E6E3'

# Headless Chrome will not shrink the viewport below ~500px, so each variant renders once at 1024 and sips scales it.
# render <out.png> <px> <variant>
#   full  opaque shell square, mark at 68%            (iOS, web "any", apple-touch)
#   mask  opaque shell square, mark at 60%            (web maskable: inside the 80% safe circle)
#   tile  transparent, rounded shell tile with shadow (macOS grid: 824/1024 tile; Android legacy; favicon)
#   fg    transparent, mark at 46%                    (Android adaptive foreground: inside the 66/108 safe circle)
render() {
  [ -f "$tmp/$3.png" ] || draw "$3"
  sips -z "$2" "$2" "$tmp/$3.png" --out "$1" >/dev/null
}
draw() {
  local bg=$shell tile="inset:0" markw=68 alpha=()
  case $1 in
    mask) markw=60 ;;
    tile) bg=transparent; alpha=(--default-background-color=00000000)
          tile="inset:9.77vw;border-radius:18.1vw;background:$shell;box-shadow:0 1vw 1vw rgba(0,0,0,.3)"; markw=68 ;;
    fg)   bg=transparent; alpha=(--default-background-color=00000000); markw=46 ;;
  esac
  cat >"$tmp/i.html" <<EOF
<style>html,body{margin:0;width:100vw;height:100vh;overflow:hidden;background:$bg}
div{position:absolute;$tile;display:flex;align-items:center;justify-content:center}
img{width:$markw%}</style><div><img src="$mark"></div>
EOF
  # Chrome can exit non-zero on teardown after writing the file, so the size check below is the real test.
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$tmp/profile" ${alpha[@]+"${alpha[@]}"} \
    --window-size=1024,1024 --screenshot="$tmp/$1.png" "file://$tmp/i.html" >/dev/null 2>&1 || true
  [ -f "$tmp/$1.png" ] && [ "$(sips -g pixelWidth -g pixelHeight "$tmp/$1.png" | awk '/pixel/{printf "%s ", $2}')" = "1024 1024 " ] || { echo "bad render: $1" >&2; exit 1; }
}

for s in 16 32 64 128 256 512 1024; do
  render "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$s.png" "$s" tile
done

# iOS: Icon-App-<pt>x<pt>@<n>x.png is <pt*n> px.
for f in ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png; do
  px=$(basename "$f" | awk -F'[-x@]' '{print $3 * $5}')
  render "$f" "$px" full
done

res=android/app/src/main/res
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  render "$res/mipmap-${d%%:*}/ic_launcher.png" "${d##*:}" tile
  render "$res/mipmap-${d%%:*}/ic_launcher_foreground.png" $(( ${d##*:} * 108 / 48 )) fg
done

render web/favicon.png 32 tile
render web/icons/Icon-192.png 192 full
render web/icons/Icon-512.png 512 full
render web/icons/Icon-maskable-192.png 192 mask
render web/icons/Icon-maskable-512.png 512 mask
echo "App icons rendered."
