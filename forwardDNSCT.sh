#!/usr/bin/env bash
#
# forwardDNSCT.sh - Refresh split DNS mappings and UDM Pro forwarders
#
# Builds per-domain CoreDNS hosts/conf files from UDM Pro client fixed IP +
# alias data and reconciles UDM Pro static DNS NS forwarders for non-primary
# domains.
# Only non-primary domains are managed. Primary domain is domains[0] in
# commonCT.json.
#
# USAGE:
#   ./forwardDNSCT.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/commonCT.sh"

usage() {
  cat <<'EOF'
Usage: forwardDNSCT.sh

Refresh split DNS CoreDNS mappings and UDM Pro NS forwarders for all
non-primary domains.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if ! config_splitdns_configured; then
  echo "[i] splitdns.hostname not configured, skipping split DNS refresh"
  exit 0
fi

SPLITDNS_HOSTNAME="$(config_get_splitdns_hostname)"
SPLITDNS_HOSTNAME_LOWER="$(echo "$SPLITDNS_HOSTNAME" | tr '[:upper:]' '[:lower:]')"
PRIMARY_DOMAIN="$(config_get_primary_domain | tr '[:upper:]' '[:lower:]')"

if [[ -z "$PRIMARY_DOMAIN" ]]; then
  echo "[!] Could not determine primary domain from commonCT.json"
  exit 1
fi

COREDNS_DIR="/mnt/docker/${SPLITDNS_HOSTNAME_LOWER}/coredns"
CONF_DIR="${COREDNS_DIR}/conf.d"
LEGACY_HOSTS_DIR="${COREDNS_DIR}/hosts"

if [[ ! -d "$COREDNS_DIR" ]]; then
  echo "[!] Split DNS CoreDNS directory not found: ${COREDNS_DIR}"
  exit 1
fi

if ! config_udmpro_configured; then
  echo "[!] UDM Pro not configured, cannot refresh split DNS"
  exit 1
fi

mkdir -p "$CONF_DIR"

UDM_HOST="$(config_get_udmpro_host)"
UDM_APIKEY="$(config_get_udmpro_apikey)"
UDM_SITE="default"
UDM_API_LAST_HTTP_CODE=""
UDM_API_LAST_PATH=""
UDM_API_LAST_BODY=""
STATIC_DNS_RECORDS_JQ='def records:
  if type == "array" then .
  elif type == "object" then
    if .data? != null then .data
    elif .results? != null then .results
    elif .records? != null then .records
    elif .items? != null then .items
    elif ((keys | length) > 0 and (keys | all(test("^[0-9]+$")))) then [to_entries[] | .value]
    else [] end
  else [] end;
records | if type == "array" then . else [] end'

declare -a FORWARD_UPSTREAMS=()
while IFS= read -r upstream; do
  [[ -z "$upstream" ]] && continue
  FORWARD_UPSTREAMS+=("$upstream")
done < <(jq -r '.splitdns.forward[]? // empty' "${CONFIG_FILE}" 2>/dev/null || true)

if [[ ${#FORWARD_UPSTREAMS[@]} -gt 0 ]]; then
  echo "  Split DNS upstreams: ${FORWARD_UPSTREAMS[*]}"
fi

udm_api_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local tmp_file url http_code body

  tmp_file="$(mktemp)"
  url="https://${UDM_HOST}${path}"

  if [[ -n "$payload" ]]; then
    http_code=$(curl -sk -X "$method" \
      -H "X-API-KEY: ${UDM_APIKEY}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -o "$tmp_file" -w '%{http_code}' \
      "$url" 2>/dev/null || echo "000")
  else
    http_code=$(curl -sk -X "$method" \
      -H "X-API-KEY: ${UDM_APIKEY}" \
      -o "$tmp_file" -w '%{http_code}' \
      "$url" 2>/dev/null || echo "000")
  fi

  body="$(cat "$tmp_file" 2>/dev/null || true)"
  rm -f "$tmp_file"

  UDM_API_LAST_HTTP_CODE="$http_code"
  UDM_API_LAST_PATH="$path"
  UDM_API_LAST_BODY="$body"

  return 0
}

udm_api_get() {
  local path="$1"
  udm_api_request "GET" "$path"
}

udm_api_post() {
  local path="$1"
  local payload="$2"
  udm_api_request "POST" "$path" "$payload"
}

udm_api_delete() {
  local path="$1"
  udm_api_request "DELETE" "$path" >/dev/null
  [[ "$UDM_API_LAST_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]
}

echo "Refreshing split DNS from UDM Pro client mappings..."
echo "  Split DNS CT: ${SPLITDNS_HOSTNAME}"
echo "  Primary domain: ${PRIMARY_DOMAIN}"

declare -a NON_PRIMARY_DOMAINS=()
while IFS= read -r domain; do
  domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$domain" ]] && continue
  if [[ "$domain" != "$PRIMARY_DOMAIN" ]]; then
    NON_PRIMARY_DOMAINS+=("$domain")
  fi
done < <(config_get_domains)

if [[ ${#NON_PRIMARY_DOMAINS[@]} -eq 0 ]]; then
  echo "  [i] No non-primary domains configured"
  exit 0
fi

# Resolve split DNS endpoint to IP for UDM NS forwarders.
SPLITDNS_IP=$(dig +short +time=2 +tries=1 "$SPLITDNS_HOSTNAME" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
if [[ -z "$SPLITDNS_IP" ]]; then
  echo "  [!] Could not resolve split DNS endpoint IP for ${SPLITDNS_HOSTNAME}"
  exit 1
fi

echo "  Split DNS endpoint IP: ${SPLITDNS_IP}"

# Reconcile UDM Pro domain forwarders (NS static DNS records) for non-primary domains.
echo "Reconciling UDM Pro NS forwarders..."
UDM_CREATED=0
UDM_UPDATED=0
UDM_DELETED=0
UDM_UNCHANGED=0
UDM_FAILED=0
STATIC_DNS_ENDPOINT=""
STATIC_DNS_JSON=""
STATIC_DNS_RECORDS_JSON=""
for candidate_endpoint in \
  "/proxy/network/v2/api/site/${UDM_SITE}/static-dns" \
  "/api/v2/site/${UDM_SITE}/static-dns"; do
  udm_api_get "$candidate_endpoint"
  response_body="$UDM_API_LAST_BODY"
  http_code="$UDM_API_LAST_HTTP_CODE"

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    echo "  [!] UDM static-dns request unauthorized (HTTP ${http_code})"
    echo "      Endpoint: ${candidate_endpoint}"
    echo "      Action: verify udmpro.apikey and API permissions"
    UDM_FAILED=$((UDM_FAILED + 1))
    break
  fi

  if [[ "$http_code" == "404" ]]; then
    echo "  [i] UDM static-dns endpoint not found (HTTP 404): ${candidate_endpoint}"
    continue
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "  [i] UDM static-dns endpoint failed (HTTP ${http_code}): ${candidate_endpoint}"
    continue
  fi

  if [[ -z "$response_body" ]]; then
    echo "  [i] UDM static-dns endpoint returned empty body: ${candidate_endpoint}"
    continue
  fi

  if ! printf '%s' "$response_body" | jq empty >/dev/null 2>&1; then
    response_preview="$(printf '%s' "$response_body" | tr '\n' ' ' | cut -c1-180)"
    echo "  [i] UDM static-dns endpoint returned non-JSON body: ${candidate_endpoint}"
    echo "      Preview: ${response_preview}"
    continue
  fi

  normalized_records="$(printf '%s' "$response_body" | jq -c "$STATIC_DNS_RECORDS_JQ" 2>/dev/null || true)"
  if [[ -z "$normalized_records" ]] || ! printf '%s' "$normalized_records" | jq -e 'type == "array"' >/dev/null 2>&1; then
    response_type="$(printf '%s' "$response_body" | jq -r 'type' 2>/dev/null || echo "unknown")"
    response_keys="$(printf '%s' "$response_body" | jq -r 'if type=="object" then (keys_unsorted | join(",")) else "n/a" end' 2>/dev/null || echo "unknown")"
    echo "  [i] UDM static-dns endpoint JSON schema mismatch: ${candidate_endpoint}"
    echo "      Root type: ${response_type}"
    echo "      Top-level keys: ${response_keys}"
    continue
  fi

  STATIC_DNS_ENDPOINT="$candidate_endpoint"
  STATIC_DNS_JSON="$response_body"
  STATIC_DNS_RECORDS_JSON="$normalized_records"
  break
done

if [[ -z "$STATIC_DNS_ENDPOINT" || -z "$STATIC_DNS_JSON" || -z "$STATIC_DNS_RECORDS_JSON" ]]; then
  echo "  [!] No compatible UDM static-dns endpoint available"
  echo "      Action: skipped UDM NS reconciliation; continuing with CoreDNS mapping refresh"
  UDM_FAILED=$((UDM_FAILED + 1))
else
  record_count="$(printf '%s' "$STATIC_DNS_RECORDS_JSON" | jq -r 'length' 2>/dev/null || echo "0")"
  echo "  [✓] Using UDM static-dns endpoint: ${STATIC_DNS_ENDPOINT} (records: ${record_count})"

  # Delete stale managed NS records for domains that are no longer non-primary.
  while IFS= read -r rec; do
    rec_type=$(echo "$rec" | jq -r '(.record_type // .type // "") | ascii_upcase')
    rec_key=$(echo "$rec" | jq -r '(.key // .name // "") | ascii_downcase')
    rec_val=$(echo "$rec" | jq -r '(.value // .data // "") | ascii_downcase')
    rec_id=$(echo "$rec" | jq -r '.record_id // .id // ._id // empty')
    [[ "$rec_type" == "NS" ]] || continue
    [[ -n "$rec_id" ]] || continue
    [[ "$rec_val" == "$SPLITDNS_IP" ]] || continue

    keep=false
    for d in "${NON_PRIMARY_DOMAINS[@]}"; do
      if [[ "$rec_key" == "$d" ]]; then
        keep=true
        break
      fi
    done

    if [[ "$keep" != true ]]; then
      if udm_api_delete "${STATIC_DNS_ENDPOINT}/${rec_id}"; then
        echo "  [-] NS forwarder deleted (stale): ${rec_key} -> ${rec_val}"
        UDM_DELETED=$((UDM_DELETED + 1))
      else
        echo "  [!] Failed to delete stale NS forwarder (HTTP ${UDM_API_LAST_HTTP_CODE}): ${rec_key} -> ${rec_val}"
        UDM_FAILED=$((UDM_FAILED + 1))
      fi
    fi
  done < <(printf '%s' "$STATIC_DNS_RECORDS_JSON" | jq -c '.[]?' 2>/dev/null)

  for domain in "${NON_PRIMARY_DOMAINS[@]}"; do
    domain_records=$(printf '%s' "$STATIC_DNS_RECORDS_JSON" \
      | jq -c --arg d "$domain" '.
          | map(select(((.record_type // .type // "") | ascii_upcase) == "NS"
                    and ((.key // .name // "") | ascii_downcase) == ($d | ascii_downcase)))
          | .[]?' 2>/dev/null || true)

    domain_had_records=false
    domain_deleted=0
    domain_failed=false
    desired_exists=false

    if [[ -n "$domain_records" ]]; then
      domain_had_records=true
      while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        rec_val=$(echo "$rec" | jq -r '(.value // .data // "") | ascii_downcase')
        rec_id=$(echo "$rec" | jq -r '.record_id // .id // ._id // empty')

        if [[ "$rec_val" == "$SPLITDNS_IP" ]]; then
          if [[ "$desired_exists" == true && -n "$rec_id" ]]; then
            if udm_api_delete "${STATIC_DNS_ENDPOINT}/${rec_id}"; then
              echo "  [~] NS forwarder updated (removed duplicate): ${domain} -> ${rec_val}"
              UDM_DELETED=$((UDM_DELETED + 1))
              domain_deleted=$((domain_deleted + 1))
            else
              echo "  [!] Failed to remove duplicate NS forwarder for ${domain} (HTTP ${UDM_API_LAST_HTTP_CODE})"
              UDM_FAILED=$((UDM_FAILED + 1))
              domain_failed=true
            fi
          else
            desired_exists=true
          fi
        else
          if [[ -n "$rec_id" ]]; then
            if udm_api_delete "${STATIC_DNS_ENDPOINT}/${rec_id}"; then
              echo "  [~] NS forwarder updated (removed wrong target): ${domain} -> ${rec_val}"
              UDM_DELETED=$((UDM_DELETED + 1))
              domain_deleted=$((domain_deleted + 1))
            else
              echo "  [!] Failed to remove NS forwarder with wrong target for ${domain} (HTTP ${UDM_API_LAST_HTTP_CODE}): ${rec_val}"
              UDM_FAILED=$((UDM_FAILED + 1))
              domain_failed=true
            fi
          fi
        fi
      done <<< "$domain_records"
    fi

    if [[ "$desired_exists" != true ]]; then
      payload=$(jq -n --arg key "$domain" --arg value "$SPLITDNS_IP" \
        '{record_type:"NS", key:$key, value:$value, enabled:true, ttl:0}')
      udm_api_post "${STATIC_DNS_ENDPOINT}" "$payload"
      create_out="$UDM_API_LAST_BODY"
      if echo "$create_out" | jq -e '.record_id // .id // ._id // .data.record_id // .meta.rc == "ok"' >/dev/null 2>&1; then
        if [[ "$domain_had_records" == true || $domain_deleted -gt 0 ]]; then
          echo "  [~] NS forwarder updated: ${domain} -> ${SPLITDNS_IP}"
          UDM_UPDATED=$((UDM_UPDATED + 1))
        else
          echo "  [+] NS forwarder created: ${domain} -> ${SPLITDNS_IP}"
          UDM_CREATED=$((UDM_CREATED + 1))
        fi
      else
        echo "  [!] Failed to create NS forwarder for ${domain} (HTTP ${UDM_API_LAST_HTTP_CODE})"
        UDM_FAILED=$((UDM_FAILED + 1))
      fi
    else
      if [[ "$domain_failed" == true ]]; then
        echo "  [!] NS forwarder reconcile encountered errors for ${domain}"
      elif [[ $domain_deleted -gt 0 ]]; then
        echo "  [~] NS forwarder updated: ${domain} -> ${SPLITDNS_IP}"
        UDM_UPDATED=$((UDM_UPDATED + 1))
      else
        echo "  [=] NS forwarder unchanged: ${domain} -> ${SPLITDNS_IP}"
        UDM_UNCHANGED=$((UDM_UNCHANGED + 1))
      fi
    fi
  done
fi

echo "UDM NS forwarder summary: created=${UDM_CREATED} updated=${UDM_UPDATED} deleted=${UDM_DELETED} unchanged=${UDM_UNCHANGED} failed=${UDM_FAILED}"
ALL_CLIENTS=$(curl -sk -H "X-API-KEY: ${UDM_APIKEY}" \
  "https://${UDM_HOST}/proxy/network/api/s/default/rest/user" 2>/dev/null || true)

if [[ -z "$ALL_CLIENTS" ]] || ! echo "$ALL_CLIENTS" | jq -e '.data' >/dev/null 2>&1; then
  echo "  [!] Failed to query UDM Pro API"
  exit 1
fi

CLIENT_ENTRIES=$(echo "$ALL_CLIENTS" | jq -r '.data[]
  | select(.use_fixedip == true)
  | select(.fixed_ip != null and .fixed_ip != "")
  | select(.name != null and .name != "")
  | "\(.fixed_ip)\t\(.name)"' 2>/dev/null \
  | awk -F'\t' 'NF==2 {print $1 "\t" tolower($2)}' \
  | sort -u)

GENERATED=0
MAP_CREATED=0
MAP_UPDATED=0
MAP_DELETED=0
MAP_UNCHANGED=0
MAP_FAILED=0
for domain in "${NON_PRIMARY_DOMAINS[@]}"; do
  hosts_file="${CONF_DIR}/${domain}.hosts"
  conf_file="${CONF_DIR}/${domain}.conf"
  legacy_hosts_file="${LEGACY_HOSTS_DIR}/${domain}"

  hosts_exists=false
  conf_exists=false
  [[ -f "$hosts_file" ]] && hosts_exists=true
  [[ -f "$conf_file" ]] && conf_exists=true

  DOMAIN_ENTRIES=$(printf '%s\n' "$CLIENT_ENTRIES" \
    | awk -F'\t' -v d="$domain" '$2 ~ ("\\." d "$") {print $1 " " $2}' \
    | sort -u)

  hosts_content=$(cat <<EOF
# Auto-generated by forwardDNSCT.sh
# Domain: ${domain}

# No fixed-ip hostnames currently found for this domain.

${DOMAIN_ENTRIES}
EOF
)

  if [[ -n "$DOMAIN_ENTRIES" ]]; then
    hosts_content=$(cat <<EOF
# Auto-generated by forwardDNSCT.sh
# Domain: ${domain}

${DOMAIN_ENTRIES}
EOF
)
  fi

  forward_stanza=""
  if [[ ${#FORWARD_UPSTREAMS[@]} -gt 0 ]]; then
    tls_targets=""
    for upstream in "${FORWARD_UPSTREAMS[@]}"; do
      tls_targets+=" tls://${upstream}"
    done
    forward_stanza="    forward .${tls_targets}"
  else
    forward_stanza="    forward . 192.168.0.1"
  fi

  conf_content=$(cat <<EOF
# Auto-generated by forwardDNSCT.sh
${domain} {
    hosts /etc/coredns/conf.d/${domain}.hosts {
        fallthrough
    }
${forward_stanza}
    cache 30
    errors
}
EOF
)

  hosts_changed=true
  conf_changed=true
  if [[ "$hosts_exists" == true ]] && cmp -s <(printf '%s\n' "$hosts_content") "$hosts_file"; then
    hosts_changed=false
  fi
  if [[ "$conf_exists" == true ]] && cmp -s <(printf '%s\n' "$conf_content") "$conf_file"; then
    conf_changed=false
  fi

  if [[ "$hosts_changed" == true ]]; then
    if ! printf '%s\n' "$hosts_content" > "$hosts_file"; then
      echo "  [!] Failed to write hosts mapping file: ${hosts_file}"
      MAP_FAILED=$((MAP_FAILED + 1))
      continue
    fi
  fi

  if [[ "$conf_changed" == true ]]; then
    if ! printf '%s\n' "$conf_content" > "$conf_file"; then
      echo "  [!] Failed to write CoreDNS config file: ${conf_file}"
      MAP_FAILED=$((MAP_FAILED + 1))
      continue
    fi
  fi

  rm -f "$legacy_hosts_file"

  entry_count=0
  if [[ -n "$DOMAIN_ENTRIES" ]]; then
    entry_count=$(printf '%s\n' "$DOMAIN_ENTRIES" | wc -l)
  fi
  if [[ "$hosts_exists" == false && "$conf_exists" == false ]]; then
    echo "  [+] Domain mapping created: ${domain} (${entry_count} host(s))"
    MAP_CREATED=$((MAP_CREATED + 1))
  elif [[ "$hosts_changed" == true || "$conf_changed" == true ]]; then
    echo "  [~] Domain mapping updated: ${domain} (${entry_count} host(s))"
    MAP_UPDATED=$((MAP_UPDATED + 1))
  else
    echo "  [=] Domain mapping unchanged: ${domain} (${entry_count} host(s))"
    MAP_UNCHANGED=$((MAP_UNCHANGED + 1))
  fi

  GENERATED=$((GENERATED + 1))
done

# Remove stale managed domain files that are no longer configured as non-primary
for conf_file in "$CONF_DIR"/*.conf; do
  [[ -f "$conf_file" ]] || continue
  if ! grep -q 'Auto-generated by forwardDNSCT.sh' "$conf_file" 2>/dev/null; then
    continue
  fi
  domain="$(basename "$conf_file" .conf | tr '[:upper:]' '[:lower:]')"
  keep=false
  for configured_domain in "${NON_PRIMARY_DOMAINS[@]}"; do
    if [[ "$domain" == "$configured_domain" ]]; then
      keep=true
      break
    fi
  done
  if [[ "$keep" != true ]]; then
    rm -f "$conf_file" "${CONF_DIR}/${domain}.hosts" "${LEGACY_HOSTS_DIR}/${domain}"
    echo "  [-] Domain mapping deleted (domain removed from config): ${domain}"
    MAP_DELETED=$((MAP_DELETED + 1))
  fi
done

echo "CoreDNS mapping summary: created=${MAP_CREATED} updated=${MAP_UPDATED} deleted=${MAP_DELETED} unchanged=${MAP_UNCHANGED} failed=${MAP_FAILED}"
# Reload CoreDNS in split DNS CT
build_ct_list
if ! resolve_ct_from_input "$SPLITDNS_HOSTNAME"; then
  echo "  [!] Could not resolve split DNS CT: ${SPLITDNS_HOSTNAME}"
  exit 1
fi

ensure_ct_running "$CTID" >/dev/null || true
if ct_exec --timeout 20 "$CTID" 'cd /mnt/docker && docker kill -s SIGUSR1 coredns >/dev/null 2>&1'; then
  echo "  [✓] CoreDNS reload signal sent"
else
  echo "  [!] Failed to signal CoreDNS reload"
fi

if [[ $GENERATED -eq 0 ]]; then
  echo "  [i] No split DNS host mappings generated"
else
  echo "  [✓] Split DNS refreshed for ${GENERATED} domain(s)"
fi
