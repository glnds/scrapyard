#!/usr/bin/env bash
# lambda-shape-scan: classify every Lambda in an account by its duration distribution.
#
# Pulls p50/p90/p99/Max of the AWS/Lambda `Duration` metric AND Sum of the
# `Errors` metric from CloudWatch GetMetricData (one API call, regardless of
# log group layout), then classifies each function by the p99/p50 ratio and
# how close p99 sits to the timeout, plus whether errors hit the wall.
#
# Classifier (relaxed vs. the post — matches industry consensus that < 5x
# is the healthy band, 5–10x is a wide tail worth a look, > 10x is skewed):
#   err >= 1 AND cliff >= 50%      -> URGENT   (errors observed near the timeout wall — timeouts confirmed)
#   p99 < --gap-floor              -> HEALTHY  (metric granularity, nothing to save)
#   cliff >= 80%                   -> URGENT   (broken, invocations hitting the timeout)
#   ratio > 10                     -> UNEVEN   (fast most runs, slow on some — mixed inputs / cold starts)
#   ratio > 5                      -> TAIL     (wide tail worth investigating — retries / contention)
#   else                           -> HEALTHY  (ratio under 5x, no meaningful waste)
#
# Cold-start suppressor:
#   If freq < 100/day AND verdict is TAIL or UNEVEN, the tail is probably
#   cold starts rather than real wait-time waste. Verdict is marked "*"
#   and de-coloured — de-emphasised, not escalated.
#
# Gap floor:
#   If p99 < --gap-floor (default 50 ms) the verdict is forced to HEALTHY.
#   At that scale the ratio signal is metric granularity, not a real tail.
#
# Read-only. Requires: aws-cli v2, jq. macOS + Linux compatible.
#
# ─── READ-ONLY GUARANTEE ────────────────────────────────────────────────────
# This script MUST remain safe to run under any AWS ReadOnlyAccess policy.
# The ONLY AWS API operations invoked are:
#   * sts:GetCallerIdentity            (identity sanity check)
#   * lambda:ListFunctions             (enumerate functions + timeouts)
#   * cloudwatch:GetMetricData         (pull p50/p90/p99/Max/SampleCount)
# Any edit that introduces a mutating verb (create-*, update-*, delete-*,
# put-*, modify-*, start-*, stop-*, terminate-*, invoke, etc.) is a regression
# and must be rejected in code review.
# ────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   lambda-shape-scan [--region REGION] [--days N] [--min-invocations N]
#                     [--gap-floor MS]
#
# --gap-floor: below this p99 in ms, the (max-p99)/p99 signal is measurement
#              noise and the verdict defaults to HEALTHY. Default 50 ms.

set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "")}"
DAYS=14
# Stable p99 estimation needs thousands of samples (industry consensus:
# Baeldung, Aerospike, Redis, OneUptime). Below 1000 invocations, p99 is
# computed from ~10 observations and is effectively "slowest of 10" —
# not a percentile. Default set to 1000 as the KISS floor; raise with
# --min-invocations for tighter CIs, lower for noisier triage.
MIN_INVOCATIONS=1000
# Below GAP_FLOOR_MS the (max-p99)/p99 ratio explodes on a trivial denominator
# and says nothing diagnostic — it just means one cold start happened. Skip it.
GAP_FLOOR_MS=50
# HEALTHY rows are safe and uninteresting — hide by default, --show-healthy
# re-includes them.
SHOW_HEALTHY=0

usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/, ""); print}' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)          REGION="$2"; shift 2 ;;
    --days)            DAYS="$2"; shift 2 ;;
    --min-invocations) MIN_INVOCATIONS="$2"; shift 2 ;;
    --gap-floor)       GAP_FLOOR_MS="$2"; shift 2 ;;
    --show-healthy)    SHOW_HEALTHY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REGION" ]] || { echo "ERROR: no region. Pass --region or set AWS_REGION." >&2; exit 2; }
for t in aws jq awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing $t" >&2; exit 2; }
done

# ANSI colors. Auto-off when stdout is not a TTY (pipes, redirects stay clean).
# Override: NO_COLOR=1 to force off; FORCE_COLOR=1 to force on.
if [[ "${NO_COLOR:-}" != "" ]]; then
  USE_COLOR=0
elif [[ "${FORCE_COLOR:-}" != "" ]]; then
  USE_COLOR=1
elif [[ -t 1 ]]; then
  USE_COLOR=1
else
  USE_COLOR=0
fi
if (( USE_COLOR )); then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[94m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi

# --- Time window (UTC, ISO-8601) -------------------------------------------
if date -v-1d +%Y >/dev/null 2>&1; then
  START_ISO=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  START_ISO=$(date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
fi
END_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# CloudWatch requires period to be a multiple of 60s. Collapsing the whole
# window into one datapoint keeps the reply small and the math identical to
# Logs Insights percentiles over the same raw sample set.
PERIOD=$((DAYS * 86400))

# --- Classifier ------------------------------------------------------------
# Relaxed to match industry consensus (OneUptime, Aerospike, Redis, SRE
# practice): p99/p50 < 5x is healthy, 5–10x is a wide tail worth investigating,
# > 10x is seriously skewed. The article's 2x threshold for MILD flagged every
# API-calling function — too strict for a real fleet. MILD is dropped.
#
# Rules (top-down):
#   err >= 1 AND cliff >= 50%      -> URGENT   (errors observed near timeout — timeouts confirmed)
#   p99 < --gap-floor              -> HEALTHY  (metric granularity, no waste)
#   cliff >= 80%                   -> URGENT   (at the timeout wall, regardless of ratio)
#   ratio > 10                     -> UNEVEN   (very skewed — cold starts, bimodal, outliers)
#   ratio > 5                      -> TAIL     (wide tail worth investigating)
#   else                           -> HEALTHY  (consistent enough — ratio < 5 is fine)
#
# Errors note: Lambda's Errors metric counts handler exceptions, OOM kills,
# AND timeouts — they are not separated. When err > 0 AND cliff >= 50% the
# tail is at the wall and at least one error happened, so the proximate
# cause is almost certainly timeouts. err > 0 with low cliff means handler
# exceptions or OOM, which the existing verdicts already classify by shape.
#
# Returns tab-separated: LABEL \t one-line-next-step.
classify() {
  local p50="$1" p99="$2" timeout_s="$3" err="$4"
  awk -v p50="$p50" -v p99="$p99" -v t="$timeout_s" -v err="$err" \
      -v floor="$GAP_FLOOR_MS" 'BEGIN{
    tms = t * 1000
    r = (p50 <= 0) ? 999 : p99 / p50
    f = (tms  <= 0) ? 0   : p99 / tms
    if (err + 0 >= 1 && f >= 0.50) {
      printf "URGENT\t%d error(s) with p99 at the wall — timeouts confirmed, fix first\n", err; exit }
    if (p99 + 0 < floor) {
      print "HEALTHY\teverything runs under " floor "ms — no waste to chase"; exit }
    if (f >= 0.80) {
      print "URGENT\tcalls are hitting the timeout and failing — fix first"; exit }
    if (r > 10) {
      print "UNEVEN\t~1% of calls take 10×+ longer than the rest — cold starts or a slow input type"; exit }
    if (r >  5) {
      print "TAIL\t~1% of calls take 5–10× longer than the rest — check retries / downstream"; exit }
    print "HEALTHY\tall calls take about the same time — nothing to investigate"
  }'
}

# --- Caller identity sanity check ------------------------------------------
ID=$(aws sts get-caller-identity --region "$REGION" --output json 2>/dev/null) \
  || { echo "ERROR: sts get-caller-identity failed — check SSO / profile." >&2; exit 2; }
ACCOUNT=$(echo "$ID" | jq -r '.Account')

# --- Enumerate functions ---------------------------------------------------
FN_JSON=$(aws lambda list-functions --region "$REGION" --output json)
FN_COUNT=$(echo "$FN_JSON" | jq '.Functions | length')
if [[ "$FN_COUNT" -eq 0 ]]; then
  echo "No Lambda functions found in $REGION." >&2; exit 0
fi

echo "Account: $ACCOUNT | Region: $REGION"
echo "Window: ${DAYS}d ($START_ISO → $END_ISO) | Min invocations: $MIN_INVOCATIONS"
echo "Enumerated $FN_COUNT function(s). Calling CloudWatch GetMetricData..."

# --- Build MetricDataQueries JSON ------------------------------------------
# Six queries per function (p50, p90, p99, mx=Maximum, n=SampleCount of
# Duration; err=Sum of Errors). Ids must match ^[a-z][a-zA-Z0-9_]*$ and be
# <= 255 chars. We use the function's index to keep Ids short and safe
# regardless of function name.
QUERIES_JSON=$(echo "$FN_JSON" | jq --argjson period "$PERIOD" '
  [.Functions | to_entries[] | . as $e
   | ($e.value.FunctionName) as $fn
   | [
       {ns: "AWS/Lambda", m: "Duration", stat: "p50",         suf: "p50"},
       {ns: "AWS/Lambda", m: "Duration", stat: "p90",         suf: "p90"},
       {ns: "AWS/Lambda", m: "Duration", stat: "p99",         suf: "p99"},
       {ns: "AWS/Lambda", m: "Duration", stat: "Maximum",     suf: "mx"},
       {ns: "AWS/Lambda", m: "Duration", stat: "SampleCount", suf: "n"},
       {ns: "AWS/Lambda", m: "Errors",   stat: "Sum",         suf: "err"}
     ]
   | map({
       Id: ("q\($e.key)_\(.suf)"),
       MetricStat: {
         Metric: {
           Namespace: .ns,
           MetricName: .m,
           Dimensions: [{Name: "FunctionName", Value: $fn}]
         },
         Period: $period,
         Stat: .stat
       }
     })
  ] | add')

# Map back: Id suffix -> (index, stat). We also keep the fn/timeout ordering.
MAP_JSON=$(echo "$FN_JSON" | jq '
  [.Functions | to_entries[]
   | {idx: .key, fn: .value.FunctionName, timeout: .value.Timeout}]')

# GetMetricData caps at 500 queries per call. Split if needed.
TOTAL_QS=$(echo "$QUERIES_JSON" | jq 'length')
BATCH_SIZE=500
OFFSET=0
RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT
: > "$RAW"

while (( OFFSET < TOTAL_QS )); do
  BATCH=$(echo "$QUERIES_JSON" | jq --argjson o "$OFFSET" --argjson s "$BATCH_SIZE" '.[$o:$o+$s]')
  aws cloudwatch get-metric-data \
    --region "$REGION" \
    --start-time "$START_ISO" \
    --end-time "$END_ISO" \
    --metric-data-queries "$BATCH" \
    --output json \
    | jq -sr '[.[].MetricDataResults[]]
              | group_by(.Id)[]
              | [.[0].Id, ([.[].Values[0] // 0] | max)]
              | @tsv' >> "$RAW"
  OFFSET=$((OFFSET + BATCH_SIZE))
done

# --- Render ---------------------------------------------------------------
# ONE table. Three article signals visible as columns:
#   ratio = p99 / p50           (how heavy the tail is)
#   gap   = (max - p99) / p99   ("daylight between p99 and Max")
#   cliff = p99 / timeout       (how close p99 sits to the wall)
# Strict article classifier still drives the Verdict column, but the columns
# let an operator read the shape without trusting the label.

ROWS="$(mktemp)"
SKIPS="$(mktemp)"
trap 'rm -f "$RAW" "$ROWS" "$SKIPS"' EXIT
: > "$ROWS"; : > "$SKIPS"

# Severity: URGENT > UNEVEN > TAIL > HEALTHY.
# Ordered by ratio magnitude: UNEVEN (> 10×) outranks TAIL (5–10×). The
# cold-start asterisk already de-emphasises UNEVEN rows whose tail is
# probably cold starts, so magnitude can drive rank without double-counting.
# Used for sort order only — rank N prefixed to each row, stripped before print.
rank_of() {
  case "$1" in
    URGENT)  echo 1 ;;
    UNEVEN)  echo 2 ;;
    TAIL)    echo 3 ;;
    HEALTHY) echo 6 ;;
    *)       echo 9 ;;
  esac
}

echo "$MAP_JSON" | jq -r '.[] | [.idx, .fn, .timeout] | @tsv' \
  | while IFS=$'\t' read -r idx fn timeout; do
      p50=$(awk -F'\t' -v k="q${idx}_p50" '$1==k{print $2}' "$RAW")
      p90=$(awk -F'\t' -v k="q${idx}_p90" '$1==k{print $2}' "$RAW")
      p99=$(awk -F'\t' -v k="q${idx}_p99" '$1==k{print $2}' "$RAW")
      mx=$( awk -F'\t' -v k="q${idx}_mx"  '$1==k{print $2}' "$RAW")
      n=$(  awk -F'\t' -v k="q${idx}_n"   '$1==k{print $2}' "$RAW")
      err=$(awk -F'\t' -v k="q${idx}_err" '$1==k{print $2}' "$RAW")
      n_int=${n%.*}; n_int=${n_int:-0}
      err_int=${err%.*}; err_int=${err_int:-0}

      if [[ "$n_int" -eq 0 ]]; then
        printf '%s\tno invocations in window\n' "$fn" >> "$SKIPS"; continue
      fi
      if [[ "$n_int" -lt "$MIN_INVOCATIONS" ]]; then
        printf '%s\t%s invocations (<%s)\n' "$fn" "$n_int" "$MIN_INVOCATIONS" >> "$SKIPS"; continue
      fi

      cls=$(classify "$p50" "$p99" "$timeout" "$err_int")
      label=${cls%%$'\t'*}
      rank=$(rank_of "$label")

      ratio=$(awk -v a="$p99" -v b="$p50" \
        'BEGIN{if(b+0<=0){print"-"}else{printf"%.1fx", a/b}}')
      # Gap meaningless when p99 is below the floor — show em-dash instead
      # of a huge-denominator noise percentage.
      gap=$(awk -v m="$mx" -v p="$p99" -v floor="$GAP_FLOOR_MS" \
        'BEGIN{if(p+0 < floor){print"-"}else{printf"%.0f%%", 100*(m-p)/p}}')
      cliff=$(awk -v p="$p99" -v t="$timeout" \
        'BEGIN{if(t+0<=0){print"-"}else{printf"%.0f%%", 100*p/(t*1000)}}')
      # Invocations per day — diagnostic for cold-start pollution.
      # Below ~100/day the container has usually cooled between calls, so
      # the distribution's tail is cold-start time, not warm-path latency.
      freq=$(awk -v n="$n_int" -v d="$DAYS" \
        'BEGIN{if(d+0<=0){print"-"}else{printf"%.0f/d", n/d}}')
      freq_val=$(awk -v n="$n_int" -v d="$DAYS" \
        'BEGIN{if(d+0<=0){print 0}else{printf "%.2f", n/d}}')

      # Cold-start annotation: when freq is low AND the verdict has any
      # speed spread (MILD/TAIL/UNEVEN/MIXED), mark with "*". Reasoning:
      # Lambda warms containers ~5–15 min; below ~100/day every call
      # cold-starts, which inflates the tail regardless of verdict. URGENT
      # and HEALTHY are excluded: URGENT is real (cold-starts can't push p99
      # to the timeout), HEALTHY has nothing to annotate.
      cold="0"
      if awk -v f="$freq_val" 'BEGIN{exit !(f+0 < 100)}'; then
        case "$label" in TAIL|UNEVEN|MIXED) cold="1" ;; esac
      fi

      printf '%s\t%s\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$label" "$fn" "$p50" "$p90" "$p99" "$mx" "$n_int" "$freq" "$ratio" "$gap" "$cliff" "$cold" "$timeout" "$err_int" \
        >> "$ROWS"
    done

CLASSIFIED=$(wc -l < "$ROWS" | tr -d ' ')
SKIPPED=$(wc -l < "$SKIPS" | tr -d ' ')
URGENT_N=$(awk -F'\t' '$2=="URGENT"' "$ROWS" | wc -l | tr -d ' ')
HEALTHY_N=$(awk -F'\t' '$2=="HEALTHY"' "$ROWS" | wc -l | tr -d ' ')

# --- Summary --------------------------------------------------------------
# Plain-English one-liner per category for the overview.
UNEVEN_N=$(awk -F'\t' '$2=="UNEVEN"' "$ROWS" | wc -l | tr -d ' ')
TAIL_N=$(  awk -F'\t' '$2=="TAIL"'   "$ROWS" | wc -l | tr -d ' ')
MIXED_N=$( awk -F'\t' '$2=="MIXED"'  "$ROWS" | wc -l | tr -d ' ')

echo
echo "=== Where is this account paying Lambda for WAITING instead of COMPUTING? ==="
echo
echo "  Lambda bills every ms of Duration — whether the function is working or idle."
echo "  If calls are slow because they WAIT on HTTP / DB / cold starts / retries, that"
echo "  waiting time is billed but produces nothing. This scan finds where."
echo
echo "  Scanned $FN_COUNT function(s): $CLASSIFIED classified, $SKIPPED below sample threshold."
echo
(( URGENT_N  > 0 )) && echo "  $URGENT_N  ${RED}URGENT${RESET}   → calls time out and fail. 100% of that Duration is pure waste."
(( UNEVEN_N  > 0 )) && echo "  $UNEVEN_N  ${YELLOW}UNEVEN${RESET}   → ~1% of calls take 10×+ longer — paying for cold starts or a rare slow input path."
(( TAIL_N    > 0 )) && echo "  $TAIL_N  ${YELLOW}TAIL${RESET}     → ~1% of calls take 5–10× longer — paying for wait-time (retries, DB, slow API)."
if (( HEALTHY_N > 0 )); then
  if (( SHOW_HEALTHY == 1 )); then
    echo "  $HEALTHY_N  ${GREEN}HEALTHY${RESET}  → calls take about the same time every run — you're paying for compute, not waiting."
  else
    echo "  $HEALTHY_N  ${GREEN}HEALTHY${RESET}  → paying for compute (not waiting). Hidden — pass --show-healthy to include."
  fi
fi
(( MIXED_N   > 0 )) && echo "  $MIXED_N  MIXED    → unusual shape. Inspect manually."

# --- Single sorted table --------------------------------------------------
# freq  = n / days        -> cold-start tell (< 100/d means cold-dominated)
# ratio = p99 / p50       -> heavy tail? (article's primary signal)
# gap   = (max-p99)/p99   -> daylight between p99 and max (outlier vs pattern)
# cliff = p99 / timeout   -> how close is p99 to the wall?
# Function names >44 chars are truncated with "…"; large n/freq values are
# given generous columns so real-world payloads don't break alignment.
echo
printf '  %-50s %9s %9s %9s %10s %11s %12s %8s %7s %6s %6s %7s   %s\n' \
  "Function" "p50ms" "p90ms" "p99ms" "max" "n" "freq" "ratio" "gap" "wall" "cliff" "err" "Verdict"
printf '  %s\n' "$(printf '%.0s-' {1..173})"

sort -t$'\t' -k1,1n -k10,10 "$ROWS" \
  | awk -F'\t' \
      -v red="$RED" -v green="$GREEN" -v yellow="$YELLOW" -v blue="$BLUE" -v reset="$RESET" \
      -v show_healthy="$SHOW_HEALTHY" '
    function cfreq(s,   n) {
      n = s + 0   # "123/d" -> 123 via atof truncation at slash
      if (n >= 1000) return green
      if (n >= 100)  return yellow
      return red
    }
    function cratio(s,   n) {
      n = s + 0
      if (n >= 5)  return red
      if (n >= 2)  return yellow
      return green
    }
    function cgap(s,   n) {
      if (s == "-") return ""   # below gap floor — no color, neutral
      n = s + 0
      if (n >= 100) return red
      if (n >= 20)  return yellow
      return green
    }
    function ccliff(s,   n) {
      n = s + 0
      if (n >= 80) return red
      if (n >= 30) return yellow
      return green
    }
    function cerr(s,   n) {
      n = s + 0
      if (n >= 1) return red
      return green
    }
    # cold-start-suspect rows (col 13 == "1") render in plain white — the
    # asterisk + freq red already flag the row; yellow would double-warn
    # for a finding that is probably NOT a real problem. URGENT stays red
    # regardless (cold starts cannot push p99 to the timeout wall).
    function cverdict(v, cold) {
      if (v == "URGENT")                     return red
      if (cold == "1")                       return ""
      if (v == "TAIL" || v == "UNEVEN")      return yellow
      if (v == "HEALTHY")                    return green
      return ""
    }
    {
      if ($2 == "HEALTHY" && show_healthy == "0") next
      verdict = $2
      if ($13 == "1") verdict = verdict "*"
      fname = $3
      if (length(fname) > 50) fname = substr(fname, 1, 49) "…"
      printf "  %-50s %9d %9d %9d %10d %11d %s%12s%s %s%8s%s %s%7s%s %s%6s%s %s%6s%s %s%7s%s   %s%-8s%s\n",
        fname, $4, $5, $6, $7, $8,
        cfreq($9),    $9,  reset,
        cratio($10),  $10, reset,
        cgap($11),    $11, reset,
        blue, $14 "s", reset,
        ccliff($12),  $12, reset,
        cerr($15),    $15, reset,
        cverdict($2, $13), verdict, reset
    }'

# Legend line only if any row is cold-start flagged (13th column == "1").
if grep -q $'\t1$' "$ROWS"; then
  echo
  echo "  * = freq < 100/d AND tail-shaped verdict: the tail is probably cold starts, not real wait-time waste."
fi

# --- Skipped (count only) --------------------------------------------------
# Don't list every skipped function — just the count. Reason: on large fleets
# this list can run to hundreds of lines and carry one bit of information
# ("below threshold"). Use --min-invocations 1 if you want them included.
if (( SKIPPED > 0 )); then
  NO_DATA=$(awk -F'\t' '$2 ~ /no invocations/' "$SKIPS" | wc -l | tr -d ' ')
  LOW_VOL=$(( SKIPPED - NO_DATA ))
  echo
  echo "=== Skipped: $SKIPPED function(s) below --min-invocations ($MIN_INVOCATIONS in ${DAYS}d) ==="
  (( NO_DATA > 0 )) && echo "             $NO_DATA with no invocations in the window"
  (( LOW_VOL > 0 )) && echo "             $LOW_VOL with some traffic but too few samples for reliable percentiles"
fi

# --- Reading guide ---------------------------------------------------------
echo
echo "=== How to read the three signals ==="
echo "  freq    invocations per day                                    ( ≥ 1000/d is always-warm )"
echo "  ratio   how much slower the slow runs are vs. the fast runs   ( < 5x is fine, 5–10x worth a look, > 10x skewed )"
echo "  gap     how extreme the single worst run is vs. the tail       ( < 20% is good; huge = one freak outlier )"
echo "  cliff   how close the tail is to the configured timeout        ( < 30% is good; ≥ 80% = at the wall )"
echo "  err     errored invocations in window (timeouts + exceptions + OOM, not separated)"
echo
echo "  freq red (< 100/d) + ratio red: the tail is probably cold starts, not a real wait-time pattern."
echo "  Lambda keeps containers warm ~5–15 min; below ~100 invocations/day almost every run cold-starts."
echo
echo "  err > 0 + cliff ≥ 50% → timeouts confirmed (the tail hit the wall AND something failed)."
echo "  err > 0 + low cliff   → handler exceptions or OOM — different waste class, not a timeout."
echo
echo "  Sub-${GAP_FLOOR_MS}ms p99 → gap shown as '-' and verdict defaults to HEALTHY."
echo "  That size is metric granularity, not a real tail — no wait-time waste to find."
echo
echo "  A Lambda is HEALTHY when all three are small. URGENT when cliff is at the wall."
echo "  A wide ratio (≥ 5x) means you're paying Lambda time for work that isn't happening —"
echo "  the tail is waiting on something (HTTP, DB, cold start). That's the waste to find."
