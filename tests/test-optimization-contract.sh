#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECON_CONTRACT="$SCRIPT_DIR/.github/agents/recon.agent.md"
OPTIMIZE_CONTRACT="$SCRIPT_DIR/.github/skills/ct-optimize/SKILL.md"
COMPOSE_INSTRUCTIONS="$SCRIPT_DIR/.github/instructions/docker-compose.instructions.md"
COMPOSE_SKILL="$SCRIPT_DIR/.github/skills/ct-compose/SKILL.md"
PROJECT_INSTRUCTIONS="$SCRIPT_DIR/.github/copilot-instructions.md"
IMAGE_VERSIONING_GUIDE="$SCRIPT_DIR/documentation/container-image-versioning.md"
OPTIMIZATION_REPORT="$SCRIPT_DIR/todos/optimization.md"
DOCUMENTATION_REPORT="$SCRIPT_DIR/documentation/optimization.md"
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

assert_contract() {
  local description=$1
  local file=$2
  shift 2

  if [[ ! -f "$file" ]]; then
    fail "$description (missing $file)"
    return
  fi

  local requirement
  for requirement in "$@"; do
    if ! grep -Fq -- "$requirement" "$file"; then
      fail "$description"
      return
    fi
  done
  pass "$description"
}

assert_contract_absent() {
  local description=$1
  local file=$2
  shift 2

  if [[ ! -f "$file" ]]; then
    fail "$description (missing $file)"
    return
  fi

  local forbidden
  for forbidden in "$@"; do
    if grep -Fq -- "$forbidden" "$file"; then
      fail "$description"
      return
    fi
  done
  pass "$description"
}

assert_prompt_flow() {
  local description=$1
  local file=$2

  if ! python3 - "$file" <<'PY'
import re
import sys

report = open(sys.argv[1], encoding="utf-8").read()
prompts = re.findall(r'```text\n(.*?)\n```', report, re.S)
assert prompts, "report contains no planning prompts"

guard = (
    "Return planning content only; do not edit files, run lifecycle or apply commands, "
    "or begin implementation. Remain in planning so I can refine the plan or use the "
    "native Start Implementation handoff."
)

for prompt in prompts:
    assert prompt.startswith("/plan "), "planning prompt does not begin with /plan"
    assert guard in prompt, "planning prompt lacks the native planning-only handoff guard"
    assert not re.search(r'(?:^|\n)```(?:sh|bash)', prompt), "planning prompt embeds a shell block"
    assert not re.search(
        r'(?:^|\s)(?:cd /root/scripts && |\./(?:refresh|upgrade|move)CT\.sh\s)',
        prompt,
    ), "planning prompt embeds an apply command"
PY
  then
    fail "$description"
    return
  fi
  pass "$description"
}

assert_report_structure() {
  local description=$1

  if ! python3 - "$OPTIMIZATION_REPORT" <<'PY'
import re
import sys
from collections import Counter

report = open(sys.argv[1], encoding="utf-8").read()

for heading in (
    "**Issues and recommendations**",
    "**Uncovered optimization prompts**",
    "**Lifecycle-covered actions — manual review only**",
):
    assert heading not in report, f"retired heading remains: {heading}"

assert "- **Coverage:**" not in report, "issue-level coverage remains"
assert len(re.findall(r'^<a id="ct-\d+"></a>$', report, re.M)) == 15

finding_pattern = re.compile(r'^#### `\[[^]]+\]` — `[^`]+`$', re.M)
action_pattern = re.compile(r'^##### Action: (.+)$', re.M)
findings = list(finding_pattern.finditer(report))
actions = action_pattern.findall(report)
assert len(findings) == 18
assert len(actions) == 34
assert all(count == 1 for count in Counter(actions).values()), "duplicate action title"
action_titles = sorted(actions, key=len, reverse=True)

for index, finding in enumerate(findings):
    end = findings[index + 1].start() if index + 1 < len(findings) else len(report)
    section = report[finding.end():end]
    actions_marker = section.find("**Actions:**")
    assert actions_marker >= 0, f"finding lacks adjacent Actions marker: {finding.group()}"
    next_ct = section.find('\n<a id="ct-')
    assert next_ct < 0 or actions_marker < next_ct, f"Actions marker escaped finding: {finding.group()}"

    if "**Actions:** None —" in section:
        assert "##### Action:" not in section
        assert "```text" not in section and "```sh" not in section
        continue

    assert "##### Action:" in section, f"actionable finding lacks action: {finding.group()}"

action_blocks = re.split(r'(?=^##### Action: )', report, flags=re.M)[1:]
for block in action_blocks:
    title = re.match(r'^##### Action: (.+)$', block, re.M).group(1)
    next_finding = finding_pattern.search(block)
    if next_finding:
        block = block[:next_finding.start()]
    action_type = re.search(r'^- \*\*Type:\*\* (prompt|lifecycle)$', block, re.M)
    owner = re.search(r'^- \*\*Owner:\*\* (ct-compose|ct-telemetry|generic|refreshCT\.sh|upgradeCT\.sh|moveCT\.sh)$', block, re.M)
    relationship = re.search(r'^- \*\*Relationship:\*\* (independent|depends on .+|blocks .+)$', block, re.M)
    assert action_type, title
    assert owner, title
    assert relationship, title
    assert re.search(r'^- \*\*Purpose:\*\* .+$', block, re.M), title

    action_type = action_type.group(1)
    owner = owner.group(1)
    relationship = relationship.group(1)
    if relationship != "independent":
      if relationship.startswith("blocks "):
        references = relationship.removeprefix("blocks ")
      else:
        references = relationship.removeprefix("depends on ")
        references = references.removesuffix(" completed and verified")
        matched_titles = []
        for candidate in action_titles:
            if candidate in references:
                references = references.replace(candidate, "")
                matched_titles.append(candidate)
        assert matched_titles, f"relationship has no action title: {title}"
        assert not re.sub(r"(?:,|\band\b|\s)+", "", references), f"unresolved relationship: {title}"

    text_blocks = re.findall(r'```text\n(.*?)\n```', block, re.S)
    shell_blocks = re.findall(r'```sh\n(.*?)\n```', block, re.S)
    if action_type == "prompt":
        assert len(text_blocks) == 1 and not shell_blocks, title
        if owner == "generic":
            assert text_blocks[0].startswith("/plan No discovered repository skill owns")
        else:
            assert text_blocks[0].startswith(f"/plan Use the {owner} skill")
    else:
        assert len(shell_blocks) == 1 and not text_blocks, title
        assert owner in shell_blocks[0], title

prompt_blocks = re.findall(r'```text\n(.*?)\n```', report, re.S)
assert len(prompt_blocks) == 19
for prompt in prompt_blocks:
    assert prompt.startswith("/plan ")
    for requirement in (
        "Acceptance criteria:",
        "project instructions",
        "affected files",
        "ordered changes",
        "dependencies",
        "scope boundaries",
        "automated and manual verification",
        "Start Implementation",
        "Preserve secrets",
    ):
        assert requirement in prompt, f"prompt requirement missing: {requirement}"

lifecycle_blocks = re.findall(r'```sh\n(.*?)\n```', report, re.S)
assert len(lifecycle_blocks) == 15
for command in lifecycle_blocks:
    assert len(command.splitlines()) == 1
    assert "--force" not in command
    assert re.fullmatch(
        r"cd /root/scripts && \./(?:refreshCT\.sh [a-z0-9.-]+(?: --size [SML]| --cores \d+ --memory \d+)?|upgradeCT\.sh [a-z0-9.-]+ --target \d+\.\d+|moveCT\.sh [a-z0-9.-]+ --node [a-z0-9.-]+)",
        command,
    ), command
    assert not ("--size" in command and ("--cores" in command or "--memory" in command))

assert "Caddy stable remains `2.11.4`" in report
assert "advisory text naming `2.11.5` is not a stable release" in report
PY
  then
    fail "$description"
    return
  fi
  pass "$description"
}

assert_contract "Recon verifies deployed and proposed image versions" "$RECON_CONTRACT" \
  "verify both the deployed version and the proposed target version" \
  "A mutable tag such as \`latest\` is not version evidence" \
  "exact registry manifest for the required platform"

assert_contract "project uses readable third-party image tags" "$PROJECT_INSTRUCTIONS" \
  "Third-party images use explicit, readable stable version tags" \
  "Do not append registry digests to Compose image references by default" \
  "sole \`:latest\` exception"

assert_contract "Compose policy separates deployment tags from digest evidence" "$COMPOSE_INSTRUCTIONS" \
  "Use an explicit, readable stable version tag for third-party images" \
  "Do not append \`@sha256:\` digests to Compose image references by default" \
  "sole floating-tag exception"

assert_contract "ct-compose follows the image versioning policy" "$COMPOSE_SKILL" \
  "select an explicit readable stable version tag" \
  "resolved digests as verification and rollback evidence" \
  "sole \`:latest\` exception"

assert_contract "Recon distinguishes image references from evidence" "$RECON_CONTRACT" \
  "explicit readable stable version tags for third-party Compose images" \
  "not as the default authored Compose reference" \
  "caddy-stepca:latest" \
  "caddy-dnsimple:latest"

assert_contract "ct-optimize recommends readable image references" "$OPTIMIZE_CONTRACT" \
  "recommend an explicit readable stable version tag" \
  "rather than making digest-appended references the default" \
  "caddy-stepca:latest" \
  "caddy-dnsimple:latest"

assert_contract "image versioning guide documents the controlled exception" "$IMAGE_VERSIONING_GUIDE" \
  "Readable deployment references" \
  "Verification and rollback evidence" \
  "Sole floating-tag exception"

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

assert_contract "ct-optimize uses inline action records" "$OPTIMIZE_CONTRACT" \
  "Treat each finding as the report's organizing unit" \
  '##### Action: <stable unique title>' \
  '**Relationship:** independent | depends on <exact action title(s)> | blocks <exact action title(s)>' \
  '**Actions:** None — <specific reason>'

assert_contract_absent "ct-optimize removes dedicated action subsections" "$OPTIMIZE_CONTRACT" \
  '**Issues and recommendations**' \
  '**Uncovered optimization prompts**' \
  '**Lifecycle-covered actions — manual review only**'

assert_contract "ct-optimize supports mixed action ownership" "$OPTIMIZE_CONTRACT" \
  "A finding may contain several prompt actions, several lifecycle actions, or both" \
  "Each prompt action must stay within one owner's contract" \
  "Every non-generic prompt owner must exist in the current run's eligible remediation-owner catalog"

assert_contract "ct-optimize makes action dependencies explicit" "$OPTIMIZE_CONTRACT" \
  "Every dependency title must resolve to exactly one action in the same report" \
  "depends on <exact prompt action title> completed and verified" \
  "Shared commands appear once under the final blocking finding"

assert_contract "ct-optimize validates lifecycle commands against code and guides" "$OPTIMIZE_CONTRACT" \
  "both the current lifecycle script implementation and its matching operator guide" \
  "Validate the exact hostname or CTID target, supported flags, option exclusivity, recommended values" \
  "no \`--force\`, no mutually exclusive resize forms"

assert_contract "ct-optimize keeps prompts implementation-ready and focused" "$OPTIMIZE_CONTRACT" \
  "Begin with \`/plan\` as the first token" \
  "Request a planning-only response" \
  "Explicitly prohibit file edits, lifecycle or apply commands" \
  "native **Start Implementation** handoff" \
  'prose such as "plan first" or "wait for confirmation" without the leading `/plan` and planning-only guard is insufficient' \
  "affected files, ordered changes, dependencies, scope boundaries" \
  "specific automated and manual verification" \
  "Preserve secrets and exclude unrelated changes" \
  "one cohesive issue owned by exactly one workflow"

assert_prompt_flow "generated report enforces native planning handoff" "$OPTIMIZATION_REPORT"
assert_prompt_flow "documentation report enforces native planning handoff" "$DOCUMENTATION_REPORT"
assert_report_structure "generated report uses valid inline actions"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]