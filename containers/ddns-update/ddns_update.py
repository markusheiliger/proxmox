#!/usr/bin/env python3
import argparse
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


LOGGER = logging.getLogger("ddns-update")
GLOBAL_UNICAST = ipaddress.IPv6Network("2000::/3")
RECORD_RE = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)
RequestJson = Callable[..., dict[str, Any]]


class ConfigurationError(ValueError):
    pass


class ApiError(RuntimeError):
    pass


@dataclass(frozen=True)
class Config:
    udm_url: str
    udm_api_key: str
    unifi_site: str
    udm_tls_verify: bool
    dnsimple_zone: str
    dnsimple_record: str | None
    dnsimple_token: str
    dnsimple_account_id: str | None
    dns_ttl: int
    update_interval: int
    health_file: Path

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Config":
        values = os.environ if env is None else env

        def required(name: str) -> str:
            value = values.get(name, "").strip()
            if not value:
                raise ConfigurationError(f"{name} is required")
            return value

        udm_url = required("UDM_URL").rstrip("/")
        parsed_url = urllib.parse.urlparse(udm_url)
        if parsed_url.scheme != "https" or not parsed_url.netloc:
            raise ConfigurationError("UDM_URL must be an https URL")

        zone = required("DNSIMPLE_ZONE").rstrip(".").lower()
        record_value = values.get("DNSIMPLE_RECORD", "").strip()
        record = record_value.rstrip(".").lower() if record_value else None
        if not RECORD_RE.fullmatch(zone):
            raise ConfigurationError("DNSIMPLE_ZONE is invalid")
        if record is not None and not RECORD_RE.fullmatch(record):
            raise ConfigurationError("DNSIMPLE_RECORD is invalid")

        ttl = parse_integer(values.get("DNS_TTL", "300"), "DNS_TTL", 60)
        interval = parse_integer(
            values.get("UPDATE_INTERVAL", "300"), "UPDATE_INTERVAL", 60
        )

        return cls(
            udm_url=udm_url,
            udm_api_key=required("UDM_API_KEY"),
            unifi_site=values.get("UNIFI_SITE", "default").strip() or "default",
            udm_tls_verify=parse_boolean(
                values.get("UDM_TLS_VERIFY", "true"), "UDM_TLS_VERIFY"
            ),
            dnsimple_zone=zone,
            dnsimple_record=record,
            dnsimple_token=required("DNSIMPLE_API_ACCESS_TOKEN"),
            dnsimple_account_id=values.get("DNSIMPLE_ACCOUNT_ID", "").strip()
            or None,
            dns_ttl=ttl,
            update_interval=interval,
            health_file=Path(
                values.get(
                    "HEALTH_FILE", "/run/ddns-update/last-success"
                ).strip()
            ),
        )


def parse_boolean(value: str, name: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ConfigurationError(f"{name} must be true or false")


def parse_integer(value: str, name: str, minimum: int) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise ConfigurationError(f"{name} must be an integer") from error
    if parsed < minimum:
        raise ConfigurationError(f"{name} must be at least {minimum}")
    return parsed


def request_json(
    method: str,
    url: str,
    headers: dict[str, str],
    payload: dict[str, Any] | None = None,
    context: ssl.SSLContext | None = None,
) -> dict[str, Any]:
    body = None
    request_headers = {"Accept": "application/json", **headers}
    if payload is not None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        url, data=body, headers=request_headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=30, context=context) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raise ApiError(f"{method} {redact_url(url)} returned HTTP {error.code}") from None
    except urllib.error.URLError as error:
        reason = type(error.reason).__name__
        raise ApiError(f"{method} {redact_url(url)} failed: {reason}") from None
    try:
        decoded = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ApiError(f"{method} {redact_url(url)} returned invalid JSON") from None
    if not isinstance(decoded, dict):
        raise ApiError(f"{method} {redact_url(url)} returned an invalid object")
    return decoded


def redact_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))


def collect_wan_ipv6(value: Any) -> list[str]:
    candidates: list[str] = []
    if isinstance(value, dict):
        wan1 = value.get("wan1")
        if isinstance(wan1, dict):
            ipv6 = wan1.get("ipv6", [])
            if isinstance(ipv6, str):
                candidates.append(ipv6)
            elif isinstance(ipv6, list):
                candidates.extend(item for item in ipv6 if isinstance(item, str))
        for nested in value.values():
            candidates.extend(collect_wan_ipv6(nested))
    elif isinstance(value, list):
        for nested in value:
            candidates.extend(collect_wan_ipv6(nested))
    return candidates


def select_global_ipv6(payload: dict[str, Any]) -> str:
    addresses: set[ipaddress.IPv6Address] = set()
    for candidate in collect_wan_ipv6(payload):
        try:
            address = ipaddress.ip_address(candidate.split("/", 1)[0])
        except ValueError:
            continue
        if isinstance(address, ipaddress.IPv6Address) and address in GLOBAL_UNICAST:
            addresses.add(address)
    if not addresses:
        raise ApiError("UDM response contains no global WAN IPv6 address")
    if len(addresses) != 1:
        raise ApiError("UDM response contains multiple global WAN IPv6 addresses")
    return str(next(iter(addresses)))


@dataclass(frozen=True)
class UdmDiscovery:
    address: str
    site_id: str | None
    device_id: str | None


def discover_udm(config: Config, requester: RequestJson = request_json) -> UdmDiscovery:
    site = urllib.parse.quote(config.unifi_site, safe="")
    url = f"{config.udm_url}/proxy/network/api/s/{site}/stat/device"
    context = None if config.udm_tls_verify else ssl._create_unverified_context()
    payload = requester(
        "GET", url, {"X-API-KEY": config.udm_api_key}, context=context
    )
    devices = payload.get("data")
    if not isinstance(devices, list):
        raise ApiError("UDM response contains no device list")

    gateways: list[tuple[dict[str, Any], set[ipaddress.IPv6Address]]] = []
    for device in devices:
        if not isinstance(device, dict) or not isinstance(device.get("wan1"), dict):
            continue
        addresses: set[ipaddress.IPv6Address] = set()
        for candidate in collect_wan_ipv6({"wan1": device["wan1"]}):
            try:
                address = ipaddress.ip_address(candidate.split("/", 1)[0])
            except ValueError:
                continue
            if isinstance(address, ipaddress.IPv6Address) and address in GLOBAL_UNICAST:
                addresses.add(address)
        if addresses:
            gateways.append((device, addresses))

    if not gateways:
        raise ApiError("UDM response contains no gateway with a global WAN IPv6 address")
    if len(gateways) != 1:
        raise ApiError("UDM response contains multiple gateways with global WAN IPv6 addresses")

    gateway, addresses = gateways[0]
    if len(addresses) != 1:
        raise ApiError("UDM gateway contains multiple global WAN IPv6 addresses")

    raw_site_id = gateway.get("site_id")
    raw_device_id = gateway.get("device_id")
    site_id = raw_site_id.strip().lower() if isinstance(raw_site_id, str) else ""
    device_id = raw_device_id.strip().lower() if isinstance(raw_device_id, str) else ""
    return UdmDiscovery(
        address=str(next(iter(addresses))),
        site_id=site_id or None,
        device_id=device_id or None,
    )


def derive_dns_record(site_id: str, device_id: str) -> str:
    normalized_site_id = site_id.strip().lower()
    normalized_device_id = device_id.strip().lower()
    if not normalized_site_id:
        raise ApiError("UDM gateway contains no site_id")
    if not normalized_device_id:
        raise ApiError("UDM gateway contains no device_id")
    record = hmac.new(
        normalized_site_id.encode(),
        normalized_device_id.encode(),
        hashlib.sha256,
    ).hexdigest()[:16]
    if not RECORD_RE.fullmatch(record):
        raise ApiError("derived DNS record is invalid")
    return record


def resolve_account_id(config: Config, requester: RequestJson) -> str:
    if config.dnsimple_account_id:
        return config.dnsimple_account_id
    payload = requester(
        "GET",
        "https://api.dnsimple.com/v2/whoami",
        dnsimple_headers(config),
    )
    account = payload.get("data", {}).get("account")
    account_id = account.get("id") if isinstance(account, dict) else None
    if not isinstance(account_id, (str, int)):
        raise ApiError("DNSimple whoami response contains no account ID")
    return str(account_id)


def dnsimple_headers(config: Config) -> dict[str, str]:
    return {"Authorization": f"Bearer {config.dnsimple_token}"}


def reconcile_dns(
    config: Config,
    address: str,
    record: str | None = None,
    dry_run: bool = False,
    requester: RequestJson = request_json,
) -> str:
    effective_record = record or config.dnsimple_record
    if effective_record is None:
        raise ApiError("DNS record has not been resolved")
    account_id = urllib.parse.quote(resolve_account_id(config, requester), safe="")
    zone = urllib.parse.quote(config.dnsimple_zone, safe="")
    base_url = f"https://api.dnsimple.com/v2/{account_id}/zones/{zone}/records"
    query = urllib.parse.urlencode(
        {"type": "AAAA", "name": effective_record}
    )
    payload = requester(
        "GET", f"{base_url}?{query}", dnsimple_headers(config)
    )
    records = payload.get("data")
    if not isinstance(records, list):
        raise ApiError("DNSimple record response contains no data list")
    exact = [
        record
        for record in records
        if isinstance(record, dict)
        and record.get("type") == "AAAA"
        and record.get("name") == effective_record
    ]
    if len(exact) > 1:
        raise ApiError("DNSimple contains multiple matching AAAA records")
    if not exact:
        if not dry_run:
            requester(
                "POST",
                base_url,
                dnsimple_headers(config),
                payload={
                    "name": effective_record,
                    "type": "AAAA",
                    "content": address,
                    "ttl": config.dns_ttl,
                },
            )
        return "create"

    record = exact[0]
    if record.get("content") == address and record.get("ttl") == config.dns_ttl:
        return "noop"
    record_id = record.get("id")
    if not isinstance(record_id, (str, int)):
        raise ApiError("DNSimple record has no ID")
    if not dry_run:
        requester(
            "PATCH",
            f"{base_url}/{urllib.parse.quote(str(record_id), safe='')}",
            dnsimple_headers(config),
            payload={"content": address, "ttl": config.dns_ttl},
        )
    return "update"


def write_health(path: Path, timestamp: float | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    temporary.write_text(f"{timestamp if timestamp is not None else time.time():.6f}\n")
    temporary.replace(path)


def health_is_fresh(config: Config, now: float | None = None) -> bool:
    try:
        timestamp = float(config.health_file.read_text().strip())
    except (OSError, ValueError):
        return False
    current = time.time() if now is None else now
    return 0 <= current - timestamp <= (config.update_interval * 3 + 60)


def reconcile_once(
    config: Config,
    dry_run: bool = False,
    requester: RequestJson = request_json,
) -> tuple[str, str, str]:
    discovery = discover_udm(config, requester)
    record = config.dnsimple_record
    if record is None:
        record = derive_dns_record(discovery.site_id or "", discovery.device_id or "")
    action = reconcile_dns(
        config,
        discovery.address,
        record=record,
        dry_run=dry_run,
        requester=requester,
    )
    if not dry_run:
        write_health(config.health_file)
    return action, discovery.address, record


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reconcile a DNSimple AAAA record with a UniFi WAN IPv6 address."
    )
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--healthcheck", action="store_true")
    parser.add_argument("--version", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.version:
        print(os.environ.get("DDNS_UPDATE_VERSION", "development"))
        return 0

    try:
        config = Config.from_env()
    except ConfigurationError as error:
        LOGGER.error("configuration error: %s", error)
        return 2

    if args.healthcheck:
        return 0 if health_is_fresh(config) else 1

    while True:
        try:
            action, address, record = reconcile_once(config, args.dry_run)
            qualifier = "would " if args.dry_run and action != "noop" else ""
            LOGGER.info(
                "%s%s record %s.%s -> %s",
                qualifier,
                action,
                record,
                config.dnsimple_zone,
                address,
            )
        except (ApiError, OSError) as error:
            LOGGER.error("reconciliation failed: %s", error)
            if args.once or args.dry_run:
                return 1
        if args.once or args.dry_run:
            return 0
        time.sleep(config.update_interval)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    raise SystemExit(main())