#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COPILOT_INSTRUCTIONS="${SCRIPT_DIR}/.github/copilot-instructions.md"
COMPOSE_SKILL="${SCRIPT_DIR}/.github/skills/ct-compose/SKILL.md"

python3 - "$COPILOT_INSTRUCTIONS" "$COMPOSE_SKILL" <<'PY'
import sys

for policy_path in sys.argv[1:]:
    with open(policy_path, encoding="utf-8") as handle:
        policy = handle.read().lower()
    assert "glances" in policy
    assert "never requires authentication" in policy
    assert "do not recommend or configure oidc, forward auth" in policy
PY

echo "1 passed, 0 failed"