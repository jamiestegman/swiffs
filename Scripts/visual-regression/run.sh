#!/bin/bash
# Pixel regression gate for rendering changes.
#
#   Scripts/visual-regression/run.sh baseline   # render cases with the current build
#   Scripts/visual-regression/run.sh check      # render again and compare byte for byte
#
# Output goes to .build/visual-regression (not committed). Render a baseline
# from a known-good commit before changing rendering code.
set -euo pipefail
cd "$(dirname "$0")/../.."
mode="${1:-check}"
root=".build/visual-regression"
cases="Scripts/visual-regression/cases"
swift build -c release --product swiffs-snapshot >/dev/null
tool="$(swift build -c release --show-bin-path)/swiffs-snapshot"

render() {
  local out="$1"
  rm -rf "$out"
  mkdir -p "$out"
  for c in "$cases"/*.json; do
    "$tool" "$c" "$out/$(basename "${c%.json}").png" >/dev/null
  done
}

case "$mode" in
baseline)
  render "$root/baseline"
  echo "baseline: $(ls "$root/baseline" | wc -l | tr -d ' ') images"
  ;;
check)
  [ -d "$root/baseline" ] || { echo "no baseline; run with 'baseline' first" >&2; exit 2; }
  render "$root/current"
  failed=0
  for image in "$root/baseline"/*.png; do
    name="$(basename "$image")"
    if ! cmp -s "$image" "$root/current/$name"; then
      echo "DIFFERS: $name"
      failed=1
    fi
  done
  [ $failed = 0 ] && echo "all $(ls "$root/baseline" | wc -l | tr -d ' ') images identical"
  exit $failed
  ;;
*)
  echo "usage: $0 baseline|check" >&2
  exit 2
  ;;
esac
