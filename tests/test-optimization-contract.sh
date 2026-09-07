#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECON_CONTRACT="$SCRIPT_DIR/.github/agents/recon.agent.md"
OPTIMIZE_CONTRACT="$SCRIPT_DIR/.github/skills/ct-optimize/SKILL.md"
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_contract() {
  local description=$1
  local file=$2
  shift 2

  local requirement
  for requirement in "$@"; do
    if ! grep -Fq -- "$requirement" "$file"; then
      fail "$description"
      return
    fi
  done
  pass "$description"
}

assert_contract "Recon verifies deployed and proposed image versions" "$RECON_CONTRACT" \
  "verify both the deployed version and the proposed target version" \
  "A mutable tag such as \`latest\` is not version evidence" \
  "exact registry manifest for the required platform"

assert_contract "Recon verifies exact image variants and dependencies" "$RECON_CONTRACT" \
  "required architecture/platform support" \
  "Required variant and derived-build dependencies" \
  "availability for every artifact"

assert_contract "Recon uses explicit retrieval outcomes" "$RECON_CONTRACT" \
  "exactly \`verified\`, \`not found\`, \`inaccessible\`, \`contradictory\`, or \`incomplete\`" \
  "Tool-call completion is not retrieval success"

assert_contract "Recon verifies the complete guest OS chain" "$RECON_CONTRACT" \
  "every required intermediate release branch and package repository" \
  "A numerically computed release chain is not evidence" \
  "Per-release proof that every intermediate branch and package repository exists and is reachable"

assert_contract "Recon fails closed without verified upgrade evidence" "$RECON_CONTRACT" \
  "unverified — no recommendation" \
  "must not produce an upgrade recommendation, target version, migration prompt, or command" \
  "No evidence row, no upgrade recommendation"

assert_contract "Recon validates advisory existence and fixed artifacts" "$RECON_CONTRACT" \
  "advisory identifier and authoritative source URL" \
  "A nonexistent or unresolved advisory cannot establish exposure or severity" \
  "must not claim that an upgrade fix is available"

assert_contract "Recon output includes image and guest OS ledgers" "$RECON_CONTRACT" \
  "### Container image evidence" \
  "Include every primary and supporting image" \
  "### Guest OS upgrade evidence"

assert_contract "ct-optimize requires complete Recon ledgers" "$OPTIMIZE_CONTRACT" \
  "A complete container image evidence ledger" \
  "A guest OS upgrade evidence ledger" \
  "Missing ledger rows or required fields are incomplete acquisition"

assert_contract "ct-optimize independently attests image targets" "$OPTIMIZE_CONTRACT" \
  "Independently attest every actionable image and guest OS upgrade" \
  "published stable target, exact registry manifest" \
  "every derived-build dependency"

assert_contract "ct-optimize independently attests OS chains" "$OPTIMIZE_CONTRACT" \
  "every intermediate branch/release and package repository" \
  "Never generate a chain by numeric sequencing alone" \
  "current \`upgradeCT.sh\` parser/path logic"

assert_contract "ct-optimize rejects synthesized upgrade evidence" "$OPTIMIZE_CONTRACT" \
  "Never synthesize a version, tag, digest, fixed release, advisory identifier, or OS chain" \
  "omit the target and upgrade action" \
  "no synthesized target, apply-ready prompt, lifecycle command"

assert_contract "ct-optimize report includes attested evidence tables" "$OPTIMIZE_CONTRACT" \
  "**Container image evidence**" \
  "The parent disposition must be no more permissive than Recon's disposition" \
  "**Guest OS upgrade evidence**" \
  "An incomplete chain must be \`unverified — no recommendation\`"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]