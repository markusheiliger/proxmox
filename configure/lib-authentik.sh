# shellcheck shell=sh
# lib-authentik.sh — shared POSIX-sh helpers for Authentik OAuth2/OIDC self-
# registration from per-CT _config/configure.sh scripts.
#
# Sourced INSIDE the CT (busybox ash) as:
#     . /mnt/docker/_config/shared/lib-authentik.sh
#
# SOURCE OF TRUTH: /root/scripts/configure/ on the Proxmox host (mirrored into
# each CT's ${DIR_DOCKER}/_config/shared/ by sync_config_shared() in commonCT.sh).
# NEVER hand-edit the delivered copy under _config/shared.
#
# Requires: jq, curl (ensure via lib-common.sh ensure_tools jq curl).
# Requires env (injected via _config/configure.env): AUTHENTIK_HOST,
# AUTHENTIK_API_TOKEN. Call ak_init once before any other ak_* helper.
#
# Informational output goes to stderr so command substitution captures stay clean.

# Derive the canonical Authentik application/provider slug for a CT.
# Default = slugified full hostname (single workload per CT, so no service
# qualifier is needed). Pass an optional service name to extend the slug as
# "<hostname-slug>-<service-slug>" for the rare CT that hosts multiple OIDC
# workloads. Slugs are lowercased; every run of non [a-z0-9] becomes a single
# '-' with leading/trailing '-' stripped (dots, underscores, etc. collapse).
# Args: $1 = hostname (e.g. dashboard.thesaints.home), $2 = service (optional)
# Echoes the slug to stdout (e.g. "dashboard-thesaints-home").
oidc_slug() {
  _osl_base=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
  _osl_base=${_osl_base#-}; _osl_base=${_osl_base%-}
  if [ -n "${2:-}" ]; then
    _osl_svc=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
    _osl_svc=${_osl_svc#-}; _osl_svc=${_osl_svc%-}
    printf '%s-%s' "$_osl_base" "$_osl_svc"
  else
    printf '%s' "$_osl_base"
  fi
}

# Initialise the Authentik API base URL from AUTHENTIK_HOST.
# Returns 1 if AUTHENTIK_HOST / AUTHENTIK_API_TOKEN are not set.
ak_init() {
  [ -n "${AUTHENTIK_HOST:-}" ] || { echo "  [!] ak_init: AUTHENTIK_HOST not set" >&2; return 1; }
  [ -n "${AUTHENTIK_API_TOKEN:-}" ] || { echo "  [!] ak_init: AUTHENTIK_API_TOKEN not set" >&2; return 1; }
  AK_API="https://${AUTHENTIK_HOST}/api/v3"
}

ak_get() {
  curl -sk -H "Authorization: Bearer ${AUTHENTIK_API_TOKEN}" \
    -H "Accept: application/json" "${AK_API}$1" 2>/dev/null
}

ak_post() {
  curl -sk -X POST -H "Authorization: Bearer ${AUTHENTIK_API_TOKEN}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    "${AK_API}$1" -d "$2" 2>/dev/null
}

ak_patch() {
  curl -sk -X PATCH -H "Authorization: Bearer ${AUTHENTIK_API_TOKEN}" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    "${AK_API}$1" -d "$2" 2>/dev/null
}

# Resolve a flow slug to its pk. Echoes pk (empty if not found).
# Args: $1 = flow slug
ak_resolve_flow() {
  ak_get "/flows/instances/?slug=$1" | jq -r '.results[0].pk // empty' 2>/dev/null
}

# Resolve OAuth2 scope-mapping names to a JSON array of their pks.
# Echoes a JSON array (e.g. ["pk1","pk2"]); "[]" when no names given/found.
# Args: $@ = scope names (e.g. openid email profile)
ak_resolve_scopes() {
  [ "$#" -eq 0 ] && { echo "[]"; return 0; }
  _ars_names=$(printf '%s\n' "$@" | jq -R . | jq -s -c .)
  _ars_json=$(ak_get "/propertymappings/provider/scope/")
  if ! echo "$_ars_json" | jq -e '.results' >/dev/null 2>&1; then
    _ars_json=$(ak_get "/propertymappings/scope/")
  fi
  _ars_out=$(echo "$_ars_json" | jq -c --argjson names "$_ars_names" \
    '[.results[] | select(.scope_name as $s | $names | index($s)) | .pk]' 2>/dev/null)
  [ -n "$_ars_out" ] && echo "$_ars_out" || echo "[]"
}

# Resolve a certificate keypair to sign OIDC id_tokens with. Without a signing
# key Authentik signs id_tokens with HS256 (symmetric, client secret); strict
# OIDC clients (go-oidc, etc.) require an asymmetric RS256 signature backed by
# JWKS, so a key-bearing certificate MUST be assigned. Picks the first keypair
# that has a private key (Authentik's default self-signed cert is RSA).
# Echoes the keypair pk (empty when none is available).
ak_resolve_signing_key() {
  ak_get "/crypto/certificatekeypairs/?has_key=true" \
    | jq -r '.results[0].pk // empty' 2>/dev/null
}

# Idempotently ensure an Authentik OAuth2 provider + application exist.
# On an existing app it SELF-HEALS the provider (re-asserts grant_types,
# redirect_uris, scopes when provided, and an RS256 signing_key) so providers
# created by older/buggier revisions are repaired on refresh. Always sets
# grant_types (omitting it leaves the provider with an empty grant_types and
# breaks every flow with invalid_request). Always assigns a signing key when one
# is available (without it Authentik signs id_tokens with HS256, which strict
# OIDC clients reject as "unexpected signature algorithm").
#
# Sets globals: OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_PROVIDER_PK
# Returns 0 on success, 1 on failure.
# Args:
#   $1 NAME            provider/application display name
#   $2 SLUG            application slug (idempotency key)
#   $3 REDIRECT_URI    strict redirect URI
#   $4 GRANT_TYPES     space-separated (e.g. "authorization_code refresh_token")
#   $5 SCOPE_NAMES     space-separated scope names, may be empty (e.g. "openid email profile")
#   $6 AUTH_FLOW_SLUG  authorization flow slug
#   $7 INVAL_FLOW_SLUG invalidation flow slug
#   $8 LAUNCH_URL      application launch URL
ak_oidc_ensure_app() {
  _aoe_name="$1"
  _aoe_slug="$2"
  _aoe_redirect="$3"
  _aoe_grants="$4"
  _aoe_scope_names="$5"
  _aoe_auth_slug="$6"
  _aoe_inval_slug="$7"
  _aoe_launch="$8"

  OIDC_CLIENT_ID=""
  OIDC_CLIENT_SECRET=""
  OIDC_PROVIDER_PK=""

  # Build JSON arrays for grant types and scope pks (word-splitting intentional).
  # shellcheck disable=SC2086
  _aoe_grants_json=$(printf '%s\n' $_aoe_grants | jq -R . | jq -s -c .)
  # shellcheck disable=SC2086
  _aoe_scopes_json=$(ak_resolve_scopes $_aoe_scope_names)
  [ -n "$_aoe_scopes_json" ] || _aoe_scopes_json="[]"

  # Resolve an RS256 signing key (id_tokens are HS256 without one, which strict
  # OIDC clients reject). Empty when Authentik has no key-bearing certificate.
  _aoe_signkey=$(ak_resolve_signing_key)

  _aoe_existing=$(ak_get "/core/applications/?slug=${_aoe_slug}")
  _aoe_provider_pk=$(echo "$_aoe_existing" | \
    jq -r ".results[] | select(.slug == \"${_aoe_slug}\") | .provider // empty" 2>/dev/null)

  if [ -n "$_aoe_provider_pk" ]; then
    echo "  [✓] Authentik application '${_aoe_slug}' already exists (provider: ${_aoe_provider_pk})" >&2
    # Self-heal the existing provider.
    if [ "$_aoe_scopes_json" != "[]" ]; then
      ak_patch "/providers/oauth2/${_aoe_provider_pk}/" "$(jq -n \
        --argjson grants "$_aoe_grants_json" \
        --arg redirect "$_aoe_redirect" \
        --argjson scopes "$_aoe_scopes_json" \
        --arg signkey "$_aoe_signkey" \
        '{grant_types:$grants, redirect_uris:[{matching_mode:"strict", url:$redirect}], property_mappings:$scopes}
         + (if $signkey != "" then {signing_key:$signkey} else {} end)')" >/dev/null 2>&1
    else
      ak_patch "/providers/oauth2/${_aoe_provider_pk}/" "$(jq -n \
        --argjson grants "$_aoe_grants_json" \
        --arg redirect "$_aoe_redirect" \
        --arg signkey "$_aoe_signkey" \
        '{grant_types:$grants, redirect_uris:[{matching_mode:"strict", url:$redirect}]}
         + (if $signkey != "" then {signing_key:$signkey} else {} end)')" >/dev/null 2>&1
    fi
    echo "    Ensured grant_types + redirect_uris + signing_key on existing provider" >&2
    _aoe_detail=$(ak_get "/providers/oauth2/${_aoe_provider_pk}/")
    OIDC_CLIENT_ID=$(echo "$_aoe_detail" | jq -r '.client_id // empty' 2>/dev/null)
    OIDC_CLIENT_SECRET=$(echo "$_aoe_detail" | jq -r '.client_secret // empty' 2>/dev/null)
    OIDC_PROVIDER_PK="$_aoe_provider_pk"
    return 0
  fi

  echo "  Creating Authentik OAuth2 provider..." >&2
  _aoe_auth_flow=$(ak_resolve_flow "$_aoe_auth_slug")
  _aoe_inval_flow=$(ak_resolve_flow "$_aoe_inval_slug")
  if [ -z "$_aoe_auth_flow" ] || [ -z "$_aoe_inval_flow" ]; then
    echo "  [!] Could not resolve Authentik flows" >&2
    return 1
  fi

  _aoe_provider_result=$(ak_post "/providers/oauth2/" "$(jq -n \
    --arg name "$_aoe_name" \
    --arg auth_flow "$_aoe_auth_flow" \
    --arg inval_flow "$_aoe_inval_flow" \
    --arg redirect "$_aoe_redirect" \
    --argjson grants "$_aoe_grants_json" \
    --argjson scopes "$_aoe_scopes_json" \
    --arg signkey "$_aoe_signkey" \
    '{name:$name, authorization_flow:$auth_flow, invalidation_flow:$inval_flow, client_type:"confidential", grant_types:$grants, redirect_uris:[{matching_mode:"strict", url:$redirect}], property_mappings:$scopes, signing_key:(if $signkey=="" then null else $signkey end)}')")
  _aoe_provider_pk=$(echo "$_aoe_provider_result" | jq -r '.pk // empty' 2>/dev/null)
  if [ -z "$_aoe_provider_pk" ]; then
    _aoe_err=$(echo "$_aoe_provider_result" | jq -r 'if .detail then .detail elif .name then .name[0] else tostring end' 2>/dev/null)
    echo "  [!] Failed to create OAuth2 provider: ${_aoe_err}" >&2
    return 1
  fi
  OIDC_CLIENT_ID=$(echo "$_aoe_provider_result" | jq -r '.client_id' 2>/dev/null)
  OIDC_CLIENT_SECRET=$(echo "$_aoe_provider_result" | jq -r '.client_secret' 2>/dev/null)
  OIDC_PROVIDER_PK="$_aoe_provider_pk"
  echo "    Provider created (pk: ${_aoe_provider_pk})" >&2

  _aoe_app_result=$(ak_post "/core/applications/" "$(jq -n \
    --arg name "$_aoe_name" \
    --arg slug "$_aoe_slug" \
    --argjson provider "$_aoe_provider_pk" \
    --arg launch "$_aoe_launch" \
    '{name:$name, slug:$slug, provider:$provider, meta_launch_url:$launch}')")
  if ! echo "$_aoe_app_result" | jq -e '.pk' >/dev/null 2>&1; then
    _aoe_err=$(echo "$_aoe_app_result" | jq -r 'if .detail then .detail elif .slug then .slug[0] else tostring end' 2>/dev/null)
    echo "  [!] Failed to create application: ${_aoe_err}" >&2
    return 1
  fi
  echo "  [✓] Authentik OAuth2 provider + application created (slug: ${_aoe_slug})" >&2
  return 0
}

# Assign an OAuth2/proxy provider to an Authentik outpost (idempotent).
# No-op when the outpost name is empty or not found.
# Args: $1 = outpost name, $2 = provider pk
ak_assign_outpost() {
  _aao_name="$1"
  _aao_ppk="$2"
  [ -n "$_aao_name" ] || return 0
  [ -n "$_aao_ppk" ] || return 0
  _aao_result=$(ak_get "/outposts/instances/?name__iexact=$(printf '%s' "$_aao_name" | jq -sRr @uri)")
  _aao_uuid=$(echo "$_aao_result" | jq -r '.results[0].pk // empty' 2>/dev/null)
  [ -n "$_aao_uuid" ] || { echo "  [i] Outpost '${_aao_name}' not found - skipping assignment" >&2; return 0; }
  _aao_current=$(echo "$_aao_result" | jq '[.results[0].providers[]]' 2>/dev/null)
  [ -n "$_aao_current" ] || _aao_current="[]"
  if ! echo "$_aao_current" | jq -e --argjson pk "$_aao_ppk" 'index($pk) != null' >/dev/null 2>&1; then
    _aao_updated=$(echo "$_aao_current" | jq --argjson pk "$_aao_ppk" '. + [$pk]')
    ak_patch "/outposts/instances/${_aao_uuid}/" "$(jq -n --argjson p "$_aao_updated" '{providers:$p}')" >/dev/null
    echo "    Provider assigned to outpost '${_aao_name}'" >&2
  fi
  return 0
}

# Ensure an Authentik group exists. Echoes its pk on stdout.
# Args: $1 = group name
ak_ensure_group() {
  _aeg_name="$1"
  _aeg_pk=$(ak_get "/core/groups/?name=${_aeg_name}" | \
    jq -r ".results[] | select(.name == \"${_aeg_name}\") | .pk // empty" 2>/dev/null)
  if [ -z "$_aeg_pk" ]; then
    _aeg_result=$(ak_post "/core/groups/" "$(jq -n --arg name "$_aeg_name" '{name:$name, is_superuser:false}')")
    _aeg_pk=$(echo "$_aeg_result" | jq -r '.pk // empty' 2>/dev/null)
    if [ -z "$_aeg_pk" ]; then
      _aeg_err=$(echo "$_aeg_result" | jq -r 'if .detail then .detail elif .name then .name[0] else tostring end' 2>/dev/null)
      echo "  [!] Failed to create group '${_aeg_name}': ${_aeg_err}" >&2
      return 1
    fi
    echo "    Group '${_aeg_name}' created (pk: ${_aeg_pk})" >&2
  else
    echo "  [✓] Group '${_aeg_name}' already exists (pk: ${_aeg_pk})" >&2
  fi
  echo "$_aeg_pk"
}

# Add all Authentik superuser(s) to a group (idempotent membership merge).
# configure.sh has no interactive operator identity, so the operator is taken to
# be the Authentik superuser(s).
# Args: $1 = group pk
ak_group_add_superusers() {
  _gas_gpk="$1"
  _gas_detail=$(ak_get "/core/groups/${_gas_gpk}/")
  _gas_current=$(echo "$_gas_detail" | jq -c '.users // []' 2>/dev/null)
  [ -n "$_gas_current" ] || _gas_current="[]"
  _gas_supers=$(ak_get "/core/users/?is_superuser=true" | jq -c '[.results[].pk]' 2>/dev/null)
  [ -n "$_gas_supers" ] || _gas_supers="[]"
  _gas_merged=$(jq -c -n --argjson a "$_gas_current" --argjson b "$_gas_supers" '($a + $b) | unique')
  _gas_current_sorted=$(echo "$_gas_current" | jq -c 'unique')
  if [ "$_gas_merged" != "$_gas_current_sorted" ]; then
    _gas_patch=$(ak_patch "/core/groups/${_gas_gpk}/" "$(jq -n --argjson users "$_gas_merged" '{users:$users}')")
    if echo "$_gas_patch" | jq -e '.pk' >/dev/null 2>&1; then
      echo "    Added Authentik superuser(s) to group" >&2
    else
      echo "  [!] Failed to update group membership" >&2
      return 1
    fi
  else
    echo "  [✓] Group membership already current" >&2
  fi
  return 0
}

# Deliver OIDC credentials (or any key=value pairs) to a service via a raw env
# file, restarting the compose service only when the content changes.
# Args: $1 = env file path, $2 = compose service name, $@ = KEY=VALUE pairs
oidc_apply_credentials() {
  _oac_file="$1"
  _oac_svc="$2"
  shift 2
  _oac_new=$(printf '%s\n' "$@")
  _oac_old=""
  [ -f "$_oac_file" ] && _oac_old=$(cat "$_oac_file")
  if [ "$_oac_new" != "$_oac_old" ]; then
    mkdir -p "$(dirname "$_oac_file")"
    printf '%s\n' "$@" > "$_oac_file"
    chmod 600 "$_oac_file"
    echo "  Credentials updated - restarting ${_oac_svc}..."
    ( cd /mnt/docker && docker compose up -d "$_oac_svc" >/dev/null 2>&1 ) || echo "  [!] ${_oac_svc} restart failed"
    echo "  [✓] ${_oac_svc} OIDC configured"
  else
    echo "  [✓] ${_oac_svc} OIDC already configured"
  fi
  return 0
}
