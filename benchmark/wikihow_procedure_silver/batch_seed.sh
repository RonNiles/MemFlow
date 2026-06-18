#!/bin/bash
# Copyright 2026 SK hynix Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Incrementally seed the WikiHow Procedure Silver corpus into MemMachine in
# batches of STEP records, waiting for MemMachine's background ingestion to
# drain between batches.
#
# For each N = STEP, 2*STEP, ... up to MAX it:
#   1. runs the seed command with --limit N (--resume-progress reuses the
#      already-ingested records, so each run only adds the next STEP records);
#   2. polls the ingestion-status endpoint until the "sessions" array is empty.
#
# Usage:
#   ./benchmark/wikihow_procedure_silver/batch_seed.sh
#
# Override defaults via env vars, e.g.:
#   STEP=500 MAX=2000 START=500 ./benchmark/wikihow_procedure_silver/batch_seed.sh
#
# Env vars:
#   STEP            batch increment (default 100)
#   START           first N to seed (default = STEP)
#   MAX             last N to seed (default 132157 = full corpus)
#   ORG_ID          MemMachine org id (default "default")
#   PROJECT_ID      MemMachine project id (default "memflow")
#   STATUS_URL      ingestion-status endpoint
#                   (default http://localhost:8080/api/v2/memories/ingestion/status)
#   POLL_INTERVAL   seconds between status polls (default 5)
#   POLL_TIMEOUT    max seconds to wait for one batch to drain (default 3600)
#   CORPUS_PATH     corpus JSONL (default data/wikihow_procedures.jsonl)
#   RESULTS_DIR     results dir (default benchmark/results)

set -euo pipefail

STEP="${STEP:-100}"
START="${START:-$STEP}"
MAX="${MAX:-132157}"
ORG_ID="${ORG_ID:-default}"
PROJECT_ID="${PROJECT_ID:-memflow}"
STATUS_URL="${STATUS_URL:-http://localhost:8080/api/v2/memories/ingestion/status}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
POLL_TIMEOUT="${POLL_TIMEOUT:-3600}"

# Resolve repo root from this script's location so the uv command's relative
# paths resolve regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CORPUS_PATH="${CORPUS_PATH:-benchmark/wikihow_procedure_silver/data/wikihow_procedures.jsonl}"
RESULTS_DIR="${RESULTS_DIR:-benchmark/results}"

# Wait until the ingestion-status endpoint reports an empty "sessions" array.
# Pass "settle" as $1 to first pause one interval — used after a seed batch so we
# don't read a stale-empty array before the just-submitted sessions register.
wait_for_ingestion() {
  local waited=0 resp summary count pending
  if [ "${1:-}" = "settle" ]; then
    sleep "$POLL_INTERVAL"
  fi
  while true; do
    if ! resp="$(curl -fsS -X POST "$STATUS_URL" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -d "{\"org_id\": \"$ORG_ID\", \"project_id\": \"$PROJECT_ID\"}")"; then
      echo "  [warn] status request failed; retrying in ${POLL_INTERVAL}s..."
      sleep "$POLL_INTERVAL"
      waited=$((waited + POLL_INTERVAL))
      continue
    fi

    # Emit "<session count> <summed pending_message_count>"; treat a
    # missing/null "sessions" as 0, and a non-JSON body counts as not-done.
    if ! summary="$(printf '%s' "$resp" | jq -r \
      '(.sessions // []) | "\(length) \([.[].pending_message_count // 0] | add // 0)"' \
      2>/dev/null)"; then
      echo "  [warn] could not parse status response; retrying..."
      sleep "$POLL_INTERVAL"
      waited=$((waited + POLL_INTERVAL))
      continue
    fi
    read -r count pending <<<"$summary"

    if [ "$count" -eq 0 ]; then
      echo "  ingestion drained (sessions empty)"
      return 0
    fi

    echo "  $count ingestion session(s), $pending pending message(s); waiting ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
    if [ "$waited" -ge "$POLL_TIMEOUT" ]; then
      echo "  [error] ingestion did not drain within ${POLL_TIMEOUT}s" >&2
      return 1
    fi
  done
}

echo "Batch-seeding WikiHow corpus: START=$START STEP=$STEP MAX=$MAX"
echo "Corpus: $CORPUS_PATH"
echo

# Drain any ingestion already in progress before the first batch.
echo "Checking for in-progress ingestion before starting..."
wait_for_ingestion
echo

for ((N = START; N <= MAX; N += STEP)); do
  echo "=== Seeding up to N=$N records ==="
  uv run benchmark/wikihow_procedure_silver/run_wikihow_procedure_silver.py \
    --corpus-path "$CORPUS_PATH" \
    --results-dir "$RESULTS_DIR" \
    --seed-only \
    --resume-progress \
    --limit "$N"

  echo "Waiting for MemMachine ingestion to complete..."
  wait_for_ingestion settle
  echo
done

echo "All batches complete (up to N=$MAX)."
