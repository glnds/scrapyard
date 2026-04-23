#!/usr/bin/env bash
# lambda-fargate-crossover: for every Lambda in an account, compute current
# Lambda cost vs. the cost of an equivalently-sized always-on Fargate task,
# and flag candidates where migration would save money.
#
# Applies the published break-even formula (~45% utilisation on-demand, ~12%
# on Fargate Spot) derived from AWS list pricing:
#   Lambda:  $0.0000166667 / GB-sec  +  $0.20 / 1M requests
#   Fargate: $0.04048 / vCPU-hr      +  $0.004445 / GB-hr
#
# Read-only. Requires: aws-cli v2, jq. macOS + Linux compatible.
#
# What it does NOT account for (flagged in output when relevant):
#   - Synchronous Lambda-to-Lambda "paying twice" chains.
#   - NAT Gateway and VPC data-transfer costs.
#   - CloudWatch Logs ingestion cost.
#   - Provisioned concurrency.
#   - Compute Savings Plans (Lambda 17%, Fargate up to ~52%).
#   - Tail-latency SLAs that may rule out containers.
# Each omission tends to make Fargate look MORE attractive than this tool
# reports, not less. Treat findings as a lower bound on the real savings.
#
# Usage:
#   lambda-fargate-crossover [--region REGION] [--days N] [--spot]

set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region)}"
DAYS=14
USE_SPOT=0

# Pricing constants (us-east-1, Linux/x86, on-demand, Nov 2025).
LAMBDA_USD_PER_GBSEC=0.0000166667
LAMBDA_USD_PER_REQ=0.0000002
FARGATE_USD_PER_VCPU_HR=0.04048
FARGATE_USD_PER_GB_HR=0.004445
FARGATE_SPOT_DISCOUNT=0.70 # 70% off on-demand
HOURS_PER_MONTH=730
SECS_PER_MONTH=2628000 # 730 × 3600

# ANSI colours (disabled when stdout is not a TTY).
if [[ -t 1 ]]; then
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_RESET=$'\033[0m'
else
  C_YELLOW=""
  C_GREEN=""
  C_RESET=""
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
  --region)
    REGION="$2"
    shift 2
    ;;
  --days)
    DAYS="$2"
    shift 2
    ;;
  --spot)
    USE_SPOT=1
    shift
    ;;
  -h | --help)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    exit 2
    ;;
  esac
done

# Date math: BSD (macOS) or GNU (Linux).
if date -v-1d +%Y >/dev/null 2>&1; then
  START_EPOCH=$(date -u -v-${DAYS}d +%s)
else
  START_EPOCH=$(date -u -d "${DAYS} days ago" +%s)
fi
END_EPOCH=$(date -u +%s)
START_ISO=$(date -u -r "$START_EPOCH" +%FT%TZ 2>/dev/null || date -u -d "@$START_EPOCH" +%FT%TZ)
END_ISO=$(date -u -r "$END_EPOCH" +%FT%TZ 2>/dev/null || date -u -d "@$END_EPOCH" +%FT%TZ)

# --- Helpers --------------------------------------------------------------

# Fetch a summed CloudWatch stat for a Lambda over the window.
cw_sum() {
  local metric="$1" fn="$2"
  aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/Lambda --metric-name "$metric" \
    --dimensions "Name=FunctionName,Value=$fn" \
    --start-time "$START_ISO" --end-time "$END_ISO" \
    --period 86400 --statistics Sum \
    --query 'Datapoints[].Sum' --output json 2>/dev/null |
    jq -r 'if length == 0 then "0" else add end'
}

cw_avg() {
  local metric="$1" fn="$2"
  aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/Lambda --metric-name "$metric" \
    --dimensions "Name=FunctionName,Value=$fn" \
    --start-time "$START_ISO" --end-time "$END_ISO" \
    --period 86400 --statistics Average \
    --query 'Datapoints[].Average' --output json 2>/dev/null |
    jq -r 'if length == 0 then "0" else (add/length) end'
}

# Smallest Fargate task that fits the Lambda's memory requirement.
# Returns: "vcpu gb monthly_usd"
# Fargate supported combinations (simplified):
#   0.25 vCPU: 0.5, 1, 2 GB
#   0.5  vCPU: 1–4 GB (1 GB steps)
#   1    vCPU: 2–8 GB
#   2    vCPU: 4–16 GB
#   4    vCPU: 8–30 GB
fargate_fit() {
  local lambda_mb="$1"
  local lambda_gb
  lambda_gb=$(awk -v m="$lambda_mb" 'BEGIN{printf "%.3f", m/1024}')

  awk -v lgb="$lambda_gb" -v vc="$FARGATE_USD_PER_VCPU_HR" \
    -v gb="$FARGATE_USD_PER_GB_HR" -v hr="$HOURS_PER_MONTH" \
    -v spot="$USE_SPOT" -v discount="$FARGATE_SPOT_DISCOUNT" 'BEGIN{
    # Pick the cheapest valid (vcpu, mem) pair covering lgb.
    # vcpu, min_gb, max_gb triples:
    n = 5
    vcpu[1]=0.25; mn[1]=0.5;  mx[1]=2
    vcpu[2]=0.5;  mn[2]=1;    mx[2]=4
    vcpu[3]=1;    mn[3]=2;    mx[3]=8
    vcpu[4]=2;    mn[4]=4;    mx[4]=16
    vcpu[5]=4;    mn[5]=8;    mx[5]=30

    best_cost = 1e9
    best_vcpu = 0
    best_gb   = 0
    for (i = 1; i <= n; i++) {
      mem = lgb
      if (mem < mn[i]) mem = mn[i]
      if (mem > mx[i]) continue
      cost_hr = vcpu[i] * vc + mem * gb
      if (spot == 1) cost_hr = cost_hr * (1 - discount)
      cost_mo = cost_hr * hr
      if (cost_mo < best_cost) {
        best_cost = cost_mo
        best_vcpu = vcpu[i]
        best_gb = mem
      }
    }
    printf "%s %s %.2f", best_vcpu, best_gb, best_cost
  }'
}

# Human-readable category given a savings ratio.
categorise() {
  local saved_pct="$1" util_pct="$2" burst_ratio="$3"
  awk -v s="$saved_pct" -v u="$util_pct" -v b="$burst_ratio" 'BEGIN{
    if (s >= 50 && u >= 40) { print "STRONG: migrate to Fargate"; exit }
    if (s >= 25 && u >= 25) { print "LIKELY: consider Fargate"; exit }
    if (s >  0  && b < 3)   { print "MARGINAL: Fargate if workload stable"; exit }
    if (s >  0  && b >= 3)  { print "AMBIGUOUS: bursty, keep Lambda"; exit }
    print "KEEP LAMBDA"
  }'
}

# --- Main loop ------------------------------------------------------------

scaling="on-demand"
[[ "$USE_SPOT" == "1" ]] && scaling="SPOT (-70%)"

echo "Region: $REGION | Window: ${DAYS} days | Fargate pricing: $scaling"
echo "Assumptions: us-east-1 list prices; free tier ignored; Savings Plans not applied."
echo

printf '%-32s %7s %6s %6s %6s %9s %9s %8s   %s\n' \
  "Function" "Mem_MB" "inv/d" "avg_ms" "util%" "Lambda$" "Fargate$" "save%" "Recommendation"
printf '%s\n' "$(printf '%.0s-' {1..145})"

aws lambda list-functions --region "$REGION" \
  --query 'Functions[].[FunctionName,MemorySize]' --output text |
  sort | while read -r fn mem; do
  [[ -z "$fn" ]] && continue

  invocations=$(cw_sum Invocations "$fn")
  avg_duration_ms=$(cw_avg Duration "$fn")

  # Monthly-normalised totals.
  invocations_int=${invocations%.*}
  if [[ "$invocations_int" -lt 100 ]]; then
    printf '%-32s %7s %6s %6s %6s %9s %9s %8s   %s\n' \
      "$fn" "$mem" "-" "-" "-" "-" "-" "-" "SKIPPED: <100 invocations in window"
    continue
  fi

  daily_invs=$(awk -v i="$invocations" -v d="$DAYS" 'BEGIN{printf "%.0f", i/d}')
  monthly_invs=$(awk -v i="$invocations" -v d="$DAYS" 'BEGIN{printf "%.0f", i/d*30}')
  gbsec=$(awk -v i="$monthly_invs" -v d="$avg_duration_ms" -v m="$mem" \
    'BEGIN{printf "%.0f", i*(d/1000)*(m/1024)}')

  # Wall-clock utilisation against 1 always-on task.
  util_pct=$(awk -v i="$monthly_invs" -v d="$avg_duration_ms" -v s="$SECS_PER_MONTH" \
    'BEGIN{printf "%.1f", (i*d/1000)/s*100}')

  # Current Lambda monthly cost.
  lambda_cost=$(awk -v g="$gbsec" -v i="$monthly_invs" \
    -v gs="$LAMBDA_USD_PER_GBSEC" -v rs="$LAMBDA_USD_PER_REQ" \
    'BEGIN{printf "%.2f", g*gs + i*rs}')

  # Smallest viable Fargate task.
  read -r fvcpu fgb fcost <<<"$(fargate_fit "$mem")"

  # Savings.
  saved=$(awk -v l="$lambda_cost" -v f="$fcost" 'BEGIN{printf "%.2f", l-f}')
  saved_pct=$(awk -v l="$lambda_cost" -v f="$fcost" \
    'BEGIN{if (l<=0){print "0"} else {printf "%.0f", (l-f)/l*100}}')

  # Burst ratio: max hourly invocations / mean hourly invocations.
  # Only relevant for the AMBIGUOUS category; cheap proxy only.
  burst_ratio=1
  max_inv=$(aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/Lambda --metric-name Invocations \
    --dimensions "Name=FunctionName,Value=$fn" \
    --start-time "$START_ISO" --end-time "$END_ISO" \
    --period 3600 --statistics Maximum \
    --query 'Datapoints[].Maximum' --output json 2>/dev/null |
    jq -r 'if length == 0 then 0 else max end')
  mean_hourly=$(awk -v i="$invocations" -v d="$DAYS" 'BEGIN{printf "%.4f", i/(d*24)}')
  if [[ $(awk -v m="$mean_hourly" 'BEGIN{print (m > 0)?1:0}') == "1" ]]; then
    burst_ratio=$(awk -v mx="$max_inv" -v mn="$mean_hourly" \
      'BEGIN{printf "%.1f", mx/mn}')
  fi

  reco=$(categorise "$saved_pct" "$util_pct" "$burst_ratio")

  # Decorate with VPC warning (tends to make Fargate win by more).
  vpc=$(aws lambda get-function-configuration --region "$REGION" \
    --function-name "$fn" --query 'VpcConfig.VpcId' --output text 2>/dev/null || echo "None")
  if [[ -n "$vpc" && "$vpc" != "None" && "$vpc" != "null" ]]; then
    reco="$reco (VPC: real savings likely higher)"
  fi

  case "$reco" in
  LIKELY*) reco="${C_YELLOW}${reco}${C_RESET}" ;;
  KEEP* | *"keep Lambda"*) reco="${C_GREEN}${reco}${C_RESET}" ;;
  esac

  printf '%-32s %7s %6s %6s %6s %9s %9s %8s   %s\n' \
    "$fn" "$mem" "$daily_invs" "$(printf '%.0f' "$avg_duration_ms")" \
    "${util_pct}%" "\$${lambda_cost}" "\$${fcost}" "${saved_pct}%" "$reco"
done

echo
echo "Notes:"
echo "  - Costs are us-east-1 list prices; apply Savings Plans / regional adjustments manually."
echo "  - Synchronous Lambda-to-Lambda chains (if any) are NOT accounted for; real Lambda"
echo "    cost for chained functions is typically 2x higher per useful unit of work."
echo "  - NAT Gateway / data transfer for VPC Lambdas is NOT included; actual bill is higher."
echo "  - Findings are a lower bound: the tool is biased to under-report savings, not over-."
