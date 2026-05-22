#!/usr/bin/env bash
#
# run_tlc.sh — run a TLA+ spec through TLC 1.8.0.
#
# Usage:
#   run_tlc.sh <spec.tla> [config.cfg]
#
# Locates tla2tools.jar (TLA2TOOLS_JAR env var first, then common install
# locations), verifies the TLC version and WARNS if it is not 1.8.0 (the
# version this skill targets), then runs:
#   java -jar <jar> -config <cfg> -deadlock <spec>
#
# -deadlock disables treating "no enabled next action" as an error, so that
# reaching a terminal lifecycle state (e.g. Delivered) is not reported as a
# false violation. Re-run without it if you specifically want progress checks.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: run_tlc.sh <spec.tla> [config.cfg]" >&2
  exit 2
fi

SPEC="$1"
if [[ ! -f "$SPEC" ]]; then
  echo "error: spec not found: $SPEC" >&2
  exit 2
fi

SPEC_DIR="$(cd "$(dirname "$SPEC")" && pwd)"
SPEC_FILE="$(basename "$SPEC")"
SPEC_BASE="${SPEC_FILE%.tla}"

# Config: explicit second arg, else sibling <base>.cfg.
if [[ $# -eq 2 ]]; then
  CFG="$2"
else
  CFG="$SPEC_DIR/$SPEC_BASE.cfg"
fi
if [[ ! -f "$CFG" ]]; then
  echo "error: config not found: $CFG" >&2
  echo "       each spec needs a sibling <base>.cfg, or pass one explicitly." >&2
  exit 2
fi
CFG_ABS="$(cd "$(dirname "$CFG")" && pwd)/$(basename "$CFG")"

# --- Locate tla2tools.jar -------------------------------------------------
find_jar() {
  if [[ -n "${TLA2TOOLS_JAR:-}" && -f "${TLA2TOOLS_JAR}" ]]; then
    echo "${TLA2TOOLS_JAR}"
    return 0
  fi
  local candidates=(
    "$HOME/.tla/tla2tools.jar"
    "$HOME/tla/tla2tools.jar"
    "$HOME/.local/lib/tla2tools.jar"
    "/usr/local/lib/tla2tools.jar"
    "/opt/tlaplus/tla2tools.jar"
    "/usr/local/Cellar/tla-plus/tla2tools.jar"
    "/opt/homebrew/lib/tla2tools.jar"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

if ! JAR="$(find_jar)"; then
  cat >&2 <<'EOF'
error: could not find tla2tools.jar.

Set the location explicitly:
    export TLA2TOOLS_JAR=/path/to/tla2tools.jar

Or place it at one of the common locations (e.g. ~/.tla/tla2tools.jar).

Download TLC 1.8.0:
    https://github.com/tlaplus/tlaplus/releases/tag/v1.8.0
EOF
  exit 3
fi

if ! command -v java >/dev/null 2>&1; then
  echo "error: java not found on PATH; TLC needs a JRE." >&2
  exit 3
fi

# --- Verify version, surface the banner -----------------------------------
# This skill targets the TLA+ tools v1.8.0 release line. Note: the TLC engine
# reports a DATE-based version (e.g. "TLC2 Version 2026.05.18.x"), not the
# literal "1.8.0", so we surface the detected banner rather than string-match a
# version that never appears, and warn only if no version line can be read.
VERSION_LINE="$(java -cp "$JAR" tlc2.TLC 2>&1 | grep -m1 -i "TLC2 Version" || true)"
if [[ -n "$VERSION_LINE" ]]; then
  echo "TLC: ${VERSION_LINE} (skill targets the v1.8.0 release)"
else
  echo "warning: could not read a TLC version banner from $JAR." >&2
  echo "         proceeding anyway; confirm this is the v1.8.0 toolset." >&2
fi

# --- Run TLC --------------------------------------------------------------
echo "Running TLC on $SPEC_FILE (config: $(basename "$CFG_ABS"))..."
cd "$SPEC_DIR"
exec java -jar "$JAR" -config "$CFG_ABS" -deadlock "$SPEC_FILE"
