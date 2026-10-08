#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: test-image.sh <image>}"
EXPECTED_RUNNER_VERSION="${EXPECTED_VERSION:-${EXPECTED_RUNNER_VERSION:-2.338.0}}"
EXPECTED_COMPOSE_VERSION="${EXPECTED_COMPOSE_VERSION:-5.6.0}"

label_version=$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
label_compose=$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.docker-compose.version"}}' "$IMAGE")

[[ "$label_version" == "$EXPECTED_RUNNER_VERSION" ]]
[[ "$label_compose" == "$EXPECTED_COMPOSE_VERSION" ]]

docker run --rm --entrypoint /bin/bash "$IMAGE" -ec '
  [[ "$(id -u runner)" == 1001 ]]
  docker --version
  docker buildx version
  docker compose version
  test -x /home/runner/run.sh
  test -x /entrypoint.sh
  for command in dockerd containerd ctr runc docker-proxy; do
    ! command -v "$command" >/dev/null
  done
'

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")
[[ "$entrypoint" == '["/entrypoint.sh"]' ]]

test_root=$(mktemp -d)
container_id=""
cleanup() {
  [[ -z "$container_id" ]] || docker rm --force "$container_id" >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT
mkdir -p "$test_root/credentials" "$test_root/result"
chmod 0777 "$test_root/result"
touch \
  "$test_root/credentials/.delivered" \
  "$test_root/credentials/credentials" \
  "$test_root/credentials/credentials_rsaparams" \
  "$test_root/credentials/runner"

cat > "$test_root/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(id -u)" > /result/uid
printf '%s\n' "$(readlink /home/runner/.runner)" > /result/runner-link
printf '%s\n' "$(readlink /home/runner/.credentials)" > /result/credentials-link
printf '%s\n' "$(readlink /home/runner/.credentials_rsaparams)" > /result/rsa-link
test -d /actions-runner/_work
test -r /run/garm/runner
EOF
chmod 0755 "$test_root/run.sh"

container_id=$(docker create \
  --env JIT_CONFIG_ENABLED=true \
  --env RUNNER_WORKDIR=/actions-runner/_work \
  --tmpfs /run/garm:rw,noexec,nosuid,nodev,size=16m,mode=0700,uid=1001,gid=1001 \
  --volume "$test_root/result:/result" \
  "$IMAGE")
docker cp "$test_root/run.sh" "$container_id:/home/runner/run.sh"
docker start "$container_id" >/dev/null
tar -C "$test_root/credentials" -cf - . | \
  docker exec --interactive --user 1001:1001 "$container_id" tar -x -p -C /run/garm
[[ "$(docker wait "$container_id")" == 0 ]]
docker cp "$container_id:/result/." "$test_root/result"

[[ "$(cat "$test_root/result/uid")" == 1001 ]]
[[ "$(cat "$test_root/result/runner-link")" == /run/garm/runner ]]
[[ "$(cat "$test_root/result/credentials-link")" == /run/garm/credentials ]]
[[ "$(cat "$test_root/result/rsa-link")" == /run/garm/credentials_rsaparams ]]