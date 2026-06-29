#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run Alloy Analyzer commands and emit a machine-readable summary.

Usage:
  alloy_check.sh --spec path/to/Foo.als [options]

Options:
  --spec PATH           Alloy spec to check (required)
  --jar PATH            Alloy dist jar (default: $ALLOY_JAR or repo .alloy/)
  --java BIN            Java executable (default: java)
  --solver NAME         Alloy solver name (default: sat4j)
  --command PATTERN     Command name/index/wildcard to run (default: all commands)
  --repeat N            Number of solutions per command (default: 1)
  --timeout-secs N      Kill Alloy after N seconds (default: 0 = no timeout)
  --out-root PATH       Run artifact root (default: <spec-dir>/.alloy-check/runs)
  -h, --help            Show this help
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 2
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

expand_user_path() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${p#~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

abs_path() {
  local p="$1"
  local d
  local b
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
    return
  fi
  d="$(dirname "$p")"
  b="$(basename "$p")"
  (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
}

abs_existing_file() {
  local p
  p="$(expand_user_path "$1")"
  [[ -f "$p" ]] || return 1
  abs_path "$p"
}

abs_maybe_missing() {
  local p
  p="$(expand_user_path "$1")"
  if [[ "$p" == /* ]]; then
    printf '%s\n' "$p"
  else
    printf '%s/%s\n' "$(pwd -P)" "$p"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    openssl dgst -sha256 "$path" | awk '{print $NF}'
  fi
}

iso_utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

quote_cmd() {
  local out=""
  local part
  local q
  for part in "$@"; do
    printf -v q '%q' "$part"
    if [[ -n "$out" ]]; then
      out="$out $q"
    else
      out="$q"
    fi
  done
  printf '%s\n' "$out"
}

mk_run_id() {
  local spec_path="$1"
  local ts
  local h
  ts="$(date '+%Y%m%d-%H%M%S')"
  h="$(sha256_file "$spec_path" 2>/dev/null | cut -c1-8 || true)"
  if [[ -n "$h" ]]; then
    printf '%s-%s\n' "$ts" "$h"
  else
    printf '%s\n' "$ts"
  fi
}

find_alloy_jar() {
  local spec_dir="$1"
  local explicit="${2:-}"
  local candidate
  local repo_root
  local guesses=()

  if [[ -n "$explicit" ]]; then
    candidate="$(expand_user_path "$explicit")"
    [[ -f "$candidate" ]] || return 1
    abs_path "$candidate"
    return
  fi

  if [[ -n "${ALLOY_JAR:-}" ]]; then
    candidate="$(expand_user_path "$ALLOY_JAR")"
    if [[ -f "$candidate" ]]; then
      abs_path "$candidate"
      return
    fi
  fi

  repo_root="$(git -C "$spec_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$repo_root" ]]; then
    guesses+=("$repo_root/.alloy/org.alloytools.alloy.dist.jar")
  fi
  guesses+=("$spec_dir/.alloy/org.alloytools.alloy.dist.jar")
  guesses+=("$(pwd -P)/.alloy/org.alloytools.alloy.dist.jar")

  for candidate in "${guesses[@]}"; do
    if [[ -f "$candidate" ]]; then
      abs_path "$candidate"
      return
    fi
  done
  return 1
}

SPEC=""
JAR=""
JAVA_BIN="java"
SOLVER="sat4j"
COMMAND_PATTERN=""
REPEAT=1
TIMEOUT_SECS=0
OUT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) [[ $# -ge 2 ]] || die "missing value for --spec"; SPEC="$2"; shift 2 ;;
    --jar) [[ $# -ge 2 ]] || die "missing value for --jar"; JAR="$2"; shift 2 ;;
    --java) [[ $# -ge 2 ]] || die "missing value for --java"; JAVA_BIN="$2"; shift 2 ;;
    --solver) [[ $# -ge 2 ]] || die "missing value for --solver"; SOLVER="$2"; shift 2 ;;
    --command) [[ $# -ge 2 ]] || die "missing value for --command"; COMMAND_PATTERN="$2"; shift 2 ;;
    --repeat) [[ $# -ge 2 ]] || die "missing value for --repeat"; REPEAT="$2"; shift 2 ;;
    --timeout-secs) [[ $# -ge 2 ]] || die "missing value for --timeout-secs"; TIMEOUT_SECS="$2"; shift 2 ;;
    --out-root) [[ $# -ge 2 ]] || die "missing value for --out-root"; OUT_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$SPEC" ]] || die "--spec is required"
[[ "$REPEAT" =~ ^[0-9]+$ ]] || die "--repeat must be a non-negative integer"
[[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]] || die "--timeout-secs must be a non-negative integer"

require_cmd jq
require_cmd "$JAVA_BIN"

spec_path="$(abs_existing_file "$SPEC" || true)"
[[ -n "$spec_path" ]] || die "spec not found: $SPEC"
spec_dir="$(dirname "$spec_path")"

jar_path="$(find_alloy_jar "$spec_dir" "$JAR" || true)"
if [[ -z "$jar_path" ]]; then
  cat >&2 <<'EOF'
Alloy dist jar not found. Set $ALLOY_JAR, place it at .alloy/org.alloytools.alloy.dist.jar, or pass --jar.
EOF
  exit 2
fi

if [[ -n "$OUT_ROOT" ]]; then
  out_root="$(abs_maybe_missing "$OUT_ROOT")"
else
  out_root="$spec_dir/.alloy-check/runs"
fi

mkdir -p "$out_root"
run_id="$(mk_run_id "$spec_path")"
run_dir="$out_root/$run_id"
if ! mkdir "$run_dir" 2>/dev/null; then
  suffix=1
  while [[ "$suffix" -le 99 ]]; do
    run_dir="$out_root/$run_id-$suffix"
    if mkdir "$run_dir" 2>/dev/null; then
      run_id="$run_id-$suffix"
      break
    fi
    suffix=$((suffix + 1))
  done
  [[ -d "$run_dir" ]] || die "unable to create unique run dir under: $out_root"
fi

stdout_path="$run_dir/alloy.stdout"
stderr_path="$run_dir/alloy.stderr"
summary_path="$run_dir/summary.json"
commands_text_path="$run_dir/commands.txt"
commands_json_path="$run_dir/commands.json"
raw_output_dir="$run_dir/raw-solutions"
instances_dir="$run_dir/instances"
counterexamples_dir="$run_dir/counterexamples"
mkdir -p "$raw_output_dir" "$instances_dir" "$counterexamples_dir"

"$JAVA_BIN" -jar "$jar_path" commands "$spec_path" >"$commands_text_path" 2>"$run_dir/commands.stderr" || true

cmd=(
  "$JAVA_BIN" -jar "$jar_path"
  exec
  -f
  -q
  -s "$SOLVER"
  -r "$REPEAT"
  -t json
  -o "$raw_output_dir"
)
if [[ -n "$COMMAND_PATTERN" ]]; then
  cmd+=(-c "$COMMAND_PATTERN")
fi
cmd+=("$spec_path")

started_epoch="$(date +%s)"
started_at_utc="$(iso_utc_now)"
timeout_flag="$run_dir/.timed_out"
watchdog_pid=""

"${cmd[@]}" >"$stdout_path" 2>"$stderr_path" &
alloy_pid=$!

if (( TIMEOUT_SECS > 0 )); then
  (
    sleep "$TIMEOUT_SECS"
    if kill -0 "$alloy_pid" 2>/dev/null; then
      : >"$timeout_flag"
      kill "$alloy_pid" 2>/dev/null || true
      sleep 2
      kill -9 "$alloy_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!
fi

if wait "$alloy_pid" 2>/dev/null; then
  exit_code=0
else
  exit_code=$?
fi

if [[ -n "$watchdog_pid" ]]; then
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
fi

timed_out=false
if [[ -f "$timeout_flag" ]]; then
  timed_out=true
  exit_code=124
fi

finished_epoch="$(date +%s)"
finished_at_utc="$(iso_utc_now)"
duration_ms=$(( (finished_epoch - started_epoch) * 1000 ))

receipt_path="$raw_output_dir/receipt.json"
receipt_exists=false
if [[ -f "$receipt_path" ]]; then
  receipt_exists=true
fi

if [[ "$receipt_exists" == true ]]; then
  jq '{
    commands: (
      .commands
      | to_entries
      | map({
          name: .value.name,
          type: .value.type,
          source: .value.source,
          scopes: (.value.scopes // []),
          expects: (.value.expects // -1),
          satisfiable: (((.value.solution // []) | length) > 0),
          solutions: ((.value.solution // []) | length)
        })
    )
  }' "$receipt_path" >"$commands_json_path"

  while IFS=$'\t' read -r name type solutions; do
    [[ "$solutions" =~ ^[0-9]+$ ]] || continue
    (( solutions > 0 )) || continue
    for f in "$raw_output_dir/$name"-solution-*.json; do
      [[ -f "$f" ]] || continue
      if [[ "$type" == "check" ]]; then
        cp "$f" "$counterexamples_dir/"
      else
        cp "$f" "$instances_dir/"
      fi
    done
  done < <(jq -r '.commands[] | [.name, .type, (.solutions|tostring)] | @tsv' "$commands_json_path")
else
  printf '{"commands":[]}\n' >"$commands_json_path"
fi

spec_sha256="$(sha256_file "$spec_path" || die "unable to hash spec file: $spec_path")"
command_json="$(printf '%s\n' "${cmd[@]}" | jq -R . | jq -s .)"
command_str="$(quote_cmd "${cmd[@]}")"

summary_json="$(
  jq -n \
    --argjson exit_code "$exit_code" \
    --argjson timed_out "$timed_out" \
    --arg started_at_utc "$started_at_utc" \
    --arg finished_at_utc "$finished_at_utc" \
    --argjson duration_ms "$duration_ms" \
    --arg spec_path "$spec_path" \
    --arg spec_dir "$spec_dir" \
    --arg jar_path "$jar_path" \
    --arg solver "$SOLVER" \
    --arg command_pattern "$COMMAND_PATTERN" \
    --argjson repeat "$REPEAT" \
    --arg spec_sha256 "$spec_sha256" \
    --argjson command "$command_json" \
    --arg command_str "$command_str" \
    --arg run_dir "$run_dir" \
    --arg stdout_path "$stdout_path" \
    --arg stderr_path "$stderr_path" \
    --arg commands_text_path "$commands_text_path" \
    --arg commands_json_path "$commands_json_path" \
    --arg receipt_path "$receipt_path" \
    --arg instances_dir "$instances_dir" \
    --arg counterexamples_dir "$counterexamples_dir" \
    --argjson receipt_exists "$receipt_exists" \
    --slurpfile commands "$commands_json_path" \
    '
    ($commands[0].commands // []) as $cmds
    | ($cmds | map(select(.expects != -1)) | map(select((.satisfiable and .expects != 1) or ((.satisfiable | not) and .expects != 0)))) as $expectation_failures
    | ($cmds | map(select(.type == "check" and .satisfiable and (.expects != 1)))) as $counterexamples
    | (
        if $timed_out then "timeout"
        elif $exit_code != 0 then "error"
        elif (($expectation_failures | length) > 0) or (($counterexamples | length) > 0) then "fail"
        else "complete"
        end
      ) as $status
    | {
        "status": $status,
        "exit_code": $exit_code,
        "timed_out": $timed_out,
        "started_at_utc": $started_at_utc,
        "finished_at_utc": $finished_at_utc,
        "duration_ms": $duration_ms,
        "spec_path": $spec_path,
        "spec_dir": $spec_dir,
        "jar_path": $jar_path,
        "solver": $solver,
        "command_pattern": (if $command_pattern == "" then null else $command_pattern end),
        "repeat": $repeat,
        "inputs": {"spec_sha256": $spec_sha256},
        "command": $command,
        "command_str": $command_str,
        "run_dir": $run_dir,
        "stdout_path": $stdout_path,
        "stderr_path": $stderr_path,
        "commands_text_path": $commands_text_path,
        "commands_json_path": $commands_json_path,
        "receipt_path": (if $receipt_exists then $receipt_path else null end),
        "instances_dir": $instances_dir,
        "counterexamples_dir": $counterexamples_dir,
        "commands": $cmds,
        "expectation_failures": $expectation_failures,
        "counterexamples": $counterexamples
      }'
)"

printf '%s\n' "$summary_json" | jq . >"$summary_path"
cat "$summary_path"

case "$(jq -r '.status' "$summary_path")" in
  complete) exit 0 ;;
  fail) exit 10 ;;
  timeout) exit 11 ;;
  *) exit 12 ;;
esac
