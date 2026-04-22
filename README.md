# scrapyard

Personal collection of random experiments, scripts, and one-off tools.

---

## Contents

- [`lambda-shape-scan.sh`](#lambda-shape-scan) — classify every Lambda in an account by
  duration distribution

---

## lambda-shape-scan

Scans all Lambda functions in an AWS account and classifies them by their execution-duration
shape. Pulls p50/p90/p99/Max from CloudWatch in a single batched API call, then flags where
you're paying Lambda billing time for **waiting** (HTTP calls, DB queries, cold starts,
retries) instead of actual compute.

Read-only — safe to run under any `ReadOnlyAccess` policy.

### Dependencies

- `aws-cli` v2
- `jq`
- `awk` (macOS or Linux)

### Usage

```bash
./lambda-shape-scan.sh --region us-east-1
```

```text
Options:
  --region REGION         AWS region (or set AWS_REGION)
  --days N                Lookback window in days (default: 14)
  --min-invocations N     Skip functions below this sample count (default: 1000)
  --gap-floor MS          Treat p99 below this value as HEALTHY (default: 50)
  --show-healthy          Include HEALTHY functions in the table (hidden by default)
  -h, --help              Print usage
```

### Verdict categories

| Verdict   | Condition                     | Meaning                                            |
| --------- | ----------------------------- | -------------------------------------------------- |
| `HEALTHY` | ratio < 5x or p99 < gap-floor | Paying for compute, not waiting                    |
| `TAIL`    | 5x <= ratio <= 10x            | ~1% of calls 5-10x slower — retries/downstream     |
| `UNEVEN`  | ratio > 10x                   | ~1% of calls 10x+ slower — cold starts/input       |
| `URGENT`  | cliff >= 80%                  | p99 at timeout wall — calls are failing            |
| `URGENT`  | err >= 1 AND cliff >= 50%     | errors observed near the wall — timeouts confirmed |

A `*` suffix means freq < 100/day: the tail is likely cold starts, not real wait-time waste.

### Output signals

| Signal  | Formula           | Rule of thumb                                             |
| ------- | ----------------- | --------------------------------------------------------- |
| `freq`  | invocations / day | >= 1000/d always-warm                                     |
| `ratio` | p99 / p50         | < 5x fine / 5-10x investigate / > 10x skewed              |
| `gap`   | (max-p99) / p99   | < 20% good / large = single freak outlier                 |
| `cliff` | p99 / timeout     | < 30% good / >= 80% at the timeout wall                   |
| `err`   | Sum of Errors     | 0 = clean / >= 1 = some failure (timeout, exception, OOM) |

### Example

```bash
AWS_PROFILE=my-sso-profile ./lambda-shape-scan.sh --region eu-west-1 --days 7
```
