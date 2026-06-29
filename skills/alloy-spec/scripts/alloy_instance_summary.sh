#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Summarize an Alloy JSON instance or counterexample.

Usage:
  alloy_instance_summary.sh --instance path/to/solution.json [--format json|text]
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 2
}

INSTANCE=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) [[ $# -ge 2 ]] || die "missing value for --instance"; INSTANCE="$2"; shift 2 ;;
    --format) [[ $# -ge 2 ]] || die "missing value for --format"; FORMAT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE" ]] || die "--instance is required"
[[ -f "$INSTANCE" ]] || die "instance not found: $INSTANCE"
[[ "$FORMAT" == "json" || "$FORMAT" == "text" ]] || die "--format must be json or text"
command -v jq >/dev/null 2>&1 || die "missing required command: jq"

summary_filter='
def instance:
  if (.instances | type) == "array" and (.instances | length) > 0 then .instances[0]
  else error("no instances found")
  end;

def values:
  instance.values // {};

def referenced_atoms:
  [
    values[]
    | to_entries[]
    | .value[]?
    | .[]?
    | select(type == "string")
  ];

def atoms:
  ([values | keys[]] + referenced_atoms)
  | unique
  | sort
  | map(select(test("^[0-9]+$") | not));

def relations:
  [
    values
    | to_entries[]
    | .key as $source
    | .value
    | to_entries[]
    | {
        source: $source,
        field: .key,
        tuples: .value
      }
  ];

{
  source: $path,
  states: ((.instances // []) | length),
  atoms: atoms,
  relations: relations,
  messages: (instance.messages // []),
  skolems: (instance.skolems // {})
}'

summary_json="$(jq -Mce --arg path "$INSTANCE" "$summary_filter" "$INSTANCE")"

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "$summary_json" | jq .
  exit 0
fi

printf '%s\n' "$summary_json" | jq -r '
  "Atoms:",
  (if (.atoms | length) == 0 then "  none" else (.atoms[] | "  " + .) end),
  "Relations:",
  (if (.relations | length) == 0 then "  none" else (.relations[] | "  \(.source).\(.field) = \(.tuples | @json)") end)
'
