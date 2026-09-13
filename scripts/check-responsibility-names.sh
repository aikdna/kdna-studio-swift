#!/usr/bin/env bash
set -euo pipefail

# Resolve the script's own physical location before deriving the repository
# root. A symlinked entry point (for example the macOS /tmp -> /private/tmp
# shim) must not silently make the gate scan the wrong tree.
script_path="$0"
while [[ -L "$script_path" ]]; do
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *) script_path="$(dirname "$script_path")/$link_target" ;;
  esac
done
root="$(cd "$(dirname "$script_path")/.." && pwd -P)"
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

# KDNA-owned generation labels are always blocked. One separate category is
# allowed: third-party mandated strings that the tooling itself fixes, namely
# SwiftPM PackageDescription platform identifiers and immutable GitHub Action
# coordinates. Nothing else is exempted.
generation_pattern='[Vv][0-9]+'
lower_v='v'
checkout_token="${lower_v}7"
action_token="${lower_v}4"
stale_token="${lower_v}11"
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
  # Third-party mandated strings, classified separately from KDNA-owned
  # generation labels and allowed. SwiftPM fixes the spelling of
  # `.macOS(.v<N>)` / `.iOS(.v<N>)` platform identifiers, so they must be
  # accepted whether the platforms array is written inline on one line or one
  # platform per line. The match is scoped to SwiftPM platform syntax in
  # Package.swift; every other `vN` token stays blocked.
  if [[ "$path" == "Package.swift" ]] &&
     { [[ "$source_line" =~ ^platforms:[[:space:]]*\[.*\.(macOS|iOS|tvOS|watchOS|visionOS)\(\.v[0-9]+\) ]] ||
       [[ "$source_line" =~ ^\.(macOS|iOS|tvOS|watchOS|visionOS)\(\.v[0-9]+\)[,]?$ ]]; }; then
    continue
  fi
  if [[ "$path|$source_line" == ".github/workflows/ci.yml|- uses: actions/checkout@${checkout_token}" ]] ||
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
