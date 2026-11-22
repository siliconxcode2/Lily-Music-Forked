#!/bin/zsh
# Lints the Swift against the rules turned on in .swift-format, but not swift-format's own
# layout, which this codebase doesn't follow; then what swift-format has no rule for.
#
#   scripts/lint.sh
set -euo pipefail
cd ${0:A:h:h}
swift=(App/Sources Packages/YTMKit/Sources Packages/YTMKit/Tests Packages/YTMKit/Package.swift)

rules=$(grep -oE '"[A-Za-z]+": true' .swift-format | cut -d'"' -f2 | paste -sd'|' -)
report=$(xcrun swift-format lint --recursive --parallel $swift 2>&1) || { print -r -- $report; exit 1 }
problems=$(
  print -r -- $report | grep -E "\[($rules)\]" || :
  grep -rnE '\b(TODO|FIXME)\b' $swift || :
)

for script in scripts/*.sh; do zsh --no-exec $script; done
plutil -convert json -o /dev/null docs/source.json

if [[ -n $problems ]]; then
  print -r -- $problems
  exit 1
fi
print "Lint passed"
