#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TEST_CT_COMMON_FILE:-${SCRIPT_DIR}/commonCT.sh}"

usage() {
  cat <<'EOF'
Usage:
  ./testCT.sh <CTID|hostname>
  ./testCT.sh --all
  ./testCT.sh

Run direct _tests/test-*.sh workload tests on each CT's current owner node.
Without arguments, select one or more containers interactively.
EOF
}

discover_workload_tests() {
  local node="${1:-}" hostname="${2:-}" workload_dir output
  [[ -n "$node" && "$hostname" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "ERROR: Invalid owner node or CT hostname for test discovery." >&2
    return 1
  }
  workload_dir="/mnt/docker/${hostname}"
  output=$(run_on_node "$node" find "$workload_dir" -mindepth 2 -maxdepth 2 \
    -path "${workload_dir}/_tests/test-*.sh" -type f -printf '%f\n') || {
    echo "ERROR: Cannot discover workload tests for ${hostname} on ${node}." >&2
    return 1
  }
  if [[ -n "$output" ]]; then
    sort <<< "$output"
  fi
  return 0
}

run_ct_tests() {
  local ctid="${1:-}" explicit="${2:-false}" hostname node test_name
  local discovery_output
  local -a tests=()

  hostname="${CT_MAP[$ctid]:-}"
  [[ -n "$hostname" ]] || {
    echo "ERROR: No hostname is available for CT ${ctid}." >&2
    return 1
  }
  node=$(get_ct_owner_node "$ctid") || return 1
  if ! discovery_output=$(discover_workload_tests "$node" "$hostname"); then
    return 1
  fi
  if [[ -n "$discovery_output" ]]; then
    mapfile -t tests <<< "$discovery_output"
  fi

  if [[ ${#tests[@]} -eq 0 ]]; then
    if [[ "$explicit" == "true" ]]; then
      echo "ERROR: No _tests/test-*.sh files found for CT ${ctid} (${hostname}) on ${node}." >&2
      return 1
    fi
    echo "skip - CT ${ctid} (${hostname}) has no workload tests on ${node}"
    TEST_CT_SKIPPED=$((TEST_CT_SKIPPED + 1))
    return 0
  fi

  echo "CT ${ctid} (${hostname}) on ${node}: ${#tests[@]} test(s)"
  for test_name in "${tests[@]}"; do
    TEST_CT_TOTAL=$((TEST_CT_TOTAL + 1))
    echo "==> ${hostname}/_tests/${test_name}"
    if run_on_node "$node" bash "/mnt/docker/${hostname}/_tests/${test_name}"; then
      TEST_CT_PASSED=$((TEST_CT_PASSED + 1))
    else
      echo "not ok - ${hostname}/_tests/${test_name}" >&2
      TEST_CT_FAILED=$((TEST_CT_FAILED + 1))
    fi
  done
}

main() {
  lifecycle_log_init "${BASH_SOURCE[0]}" "$@"
  local mode="interactive" target="" argument ctid selected_index=0
  local -a selected_cts=()
  TEST_CT_TOTAL=0
  TEST_CT_PASSED=0
  TEST_CT_FAILED=0
  TEST_CT_SKIPPED=0

  while [[ $# -gt 0 ]]; do
    argument="$1"
    case "$argument" in
      --all)
        [[ "$mode" == "interactive" && -z "$target" ]] || {
          echo "ERROR: --all cannot be combined with another target." >&2
          return 1
        }
        mode="all"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      -*)
        echo "ERROR: Unknown option '${argument}'." >&2
        usage >&2
        return 1
        ;;
      *)
        [[ "$mode" == "interactive" && -z "$target" ]] || {
          echo "ERROR: Only one CTID or hostname may be specified." >&2
          return 1
        }
        mode="explicit"
        target="$argument"
        shift
        ;;
    esac
  done

  [[ $EUID -eq 0 ]] || {
    echo "ERROR: Run testCT.sh as root on the administrative node." >&2
    return 1
  }
  build_ct_list || return 1

  case "$mode" in
    explicit)
      resolve_ct_from_input "$target" || return 1
      selected_cts=("$CTID")
      ;;
    all)
      selected_cts=("${CT_LIST[@]}")
      ;;
    interactive)
      select_ct_interactive_multi "test" || return 1
      selected_cts=("${SELECTED_CTS[@]}")
      ;;
  esac
  [[ ${#selected_cts[@]} -gt 0 ]] || {
    echo "ERROR: No containers selected for testing." >&2
    return 1
  }

  status_bar_init
  for ctid in "${selected_cts[@]}"; do
    selected_index=$((selected_index + 1))
    status_progress "$selected_index" "${#selected_cts[@]}" "Testing CT ${ctid}"
    if ! run_ct_tests "$ctid" "$([[ "$mode" == "explicit" ]] && echo true || echo false)"; then
      TEST_CT_FAILED=$((TEST_CT_FAILED + 1))
    fi
  done
  status_bar_cleanup

  echo "${TEST_CT_PASSED} passed, ${TEST_CT_FAILED} failed, ${TEST_CT_SKIPPED} skipped"
  [[ "$TEST_CT_FAILED" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi