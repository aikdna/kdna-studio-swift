#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-working-tree}"
scan_root="$root"
temporary=""

cleanup() {
  if [[ -n "$temporary" ]]; then
    rm -rf "$temporary"
  fi
}
trap cleanup EXIT

case "$mode" in
  working-tree)
    ;;
  archive)
    temporary="$(mktemp -d)"
    git -C "$root" archive HEAD | tar -xf - -C "$temporary"
    scan_root="$temporary"
    ;;
  *)
    echo "usage: $0 [working-tree|archive]" >&2
    exit 2
    ;;
esac

# KDNA-owned generation labels are always blocked. The only exact exceptions
# are syntax controlled by Swift PackageDescription and immutable third-party
# GitHub Action coordinates.
generation_pattern='[Vv][0-9]+'
lower_v='v'
swift_macos_token="${lower_v}13"
swift_ios_token="${lower_v}16"
checkout_token="${lower_v}7"
action_token="${lower_v}4"
stale_token="${lower_v}10"
findings="$(mktemp)"
retired_findings="$(mktemp)"
trap 'rm -f "$findings" "$retired_findings"; cleanup' EXIT

(
  cd "$scan_root"
  rg --hidden \
    --glob '!.git/**' \
    --glob '!.build/**' \
    --glob '!Package.resolved' \
    --no-heading -n -o "$generation_pattern" . || true
) > "$findings"

failures=0
while IFS=: read -r path line token; do
  path="${path#./}"
  [[ -z "$path" ]] && continue
  source_line="$(sed -n "${line}p" "$scan_root/$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$path|$source_line" == "Package.swift|.macOS(.${swift_macos_token})," ]] ||
     [[ "$path|$source_line" == "Package.swift|.iOS(.${swift_ios_token})" ]] ||
     [[ "$path|$source_line" == ".github/workflows/ci.yml|- uses: actions/checkout@${checkout_token}" ]] ||
     [[ "$path|$source_line" == ".github/workflows/codeql-swift.yml|uses: actions/checkout@${checkout_token}" ]] ||
     [[ "$path|$source_line" == ".github/workflows/codeql-swift.yml|uses: github/codeql-action/init@${action_token}" ]] ||
     [[ "$path|$source_line" == ".github/workflows/codeql-swift.yml|uses: github/codeql-action/autobuild@${action_token}" ]] ||
     [[ "$path|$source_line" == ".github/workflows/codeql-swift.yml|uses: github/codeql-action/analyze@${action_token}" ]] ||
     [[ "$path|$source_line" == ".github/workflows/stale.yml|- uses: actions/stale@${stale_token}" ]]; then
    continue
  fi
  echo "blocked generation label: $path:$line:$token" >&2
  failures=$((failures + 1))
done < "$findings"

# Build the retired vocabulary without embedding a blocked generation label in
# the gate itself. These are exact protocol identifiers, not broad prose terms.
one='1'
retired_tokens=(
  "studio-build-report-${lower_v}${one}"
  "human-lock-report-${lower_v}${one}"
  "quality-gate-report-${lower_v}${one}"
  "eval-report-${lower_v}${one}"
  "studio-build-receipt-${lower_v}${one}"
  "judgment-profile-${lower_v}${one}"
  "kdna-password-protected-${lower_v}${one}"
  "kdna-runtime-entry-set-${lower_v}${one}"
  "context-capsule-${lower_v}${one}"
  "kdna_""version"
  "kdna.context.""capsule"
)

for token in "${retired_tokens[@]}"; do
  (
    cd "$scan_root"
    rg --hidden \
      --glob '!.git/**' \
      --glob '!.build/**' \
      --glob '!Package.resolved' \
      --glob '!scripts/check-responsibility-names.sh' \
      --no-heading -n -F "$token" . || true
  ) >> "$retired_findings"
done

if [[ -s "$retired_findings" ]]; then
  sort -u "$retired_findings" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
  echo "responsibility naming gate failed with $failures finding group(s)" >&2
  exit 1
fi

echo "responsibility naming gate passed ($mode)"
