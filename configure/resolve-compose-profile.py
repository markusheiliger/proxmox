#!/usr/bin/env python3
"""Validate Compose profile declarations and resolve persisted IMDS winners."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any

import yaml


class ProfileError(Exception):
    pass


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_mapping(
    loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    explicit_keys: set[Any] = set()
    for key_node, value_node in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":
            continue
        key = loader.construct_object(key_node, deep=deep)
        if key in explicit_keys:
            raise ProfileError(f"duplicate YAML key: {key}")
        explicit_keys.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping
)


def load_compose(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as compose_file:
            model = yaml.load(compose_file, Loader=UniqueKeyLoader)
    except (OSError, yaml.YAMLError) as error:
        raise ProfileError(f"cannot parse {path}: {error}") from error
    if not isinstance(model, dict):
        raise ProfileError("Compose document must be a mapping")
    if "x-profiles" in model:
        raise ProfileError("x-profiles is obsolete; declare profiles on services")
    return model


def compose_profiles(model: dict[str, Any]) -> set[str]:
    services = model.get("services")
    if not isinstance(services, dict):
        raise ProfileError("services must be a mapping")
    profiles: set[str] = set()
    for service_name, service in services.items():
        if not isinstance(service, dict):
            raise ProfileError(f"service {service_name} must be a mapping")
        service_profiles = service.get("profiles", [])
        if not isinstance(service_profiles, list) or not all(
            isinstance(profile, str) and profile for profile in service_profiles
        ):
            raise ProfileError(f"service {service_name} has invalid profiles")
        profiles.update(service_profiles)
    return profiles


def managed_compose_profiles(
    model: dict[str, Any], managed_groups: set[str]
) -> dict[str, list[str]]:
    available_profiles = compose_profiles(model)
    validated: dict[str, list[str]] = {}
    for profile in sorted(available_profiles):
        if not re.fullmatch(r"[a-z0-9_]+-[a-z0-9_]+", profile):
            continue
        group, _ = profile.split("-", 1)
        if group in managed_groups:
            validated.setdefault(group, []).append(profile)
    return validated


def load_imds_profiles(path: Path) -> list[str]:
    try:
        with path.open(encoding="utf-8") as profiles_file:
            profiles = json.load(profiles_file)
    except (OSError, json.JSONDecodeError) as error:
        raise ProfileError(f"cannot read IMDS profiles from {path}: {error}") from error
    if not isinstance(profiles, list) or not all(
        isinstance(profile, str)
        and re.fullmatch(r"[a-z0-9_]+-[a-z0-9_]+", profile)
        for profile in profiles
    ):
        raise ProfileError("IMDS profiles must be an array of sanitized profile names")
    if len(profiles) != len(set(profiles)):
        raise ProfileError("IMDS profiles must not contain duplicates")
    return profiles


def select_profiles(groups: dict[str, list[str]], imds_profiles: list[str]) -> list[str]:
    selected: list[str] = []
    for group, supported in groups.items():
        winners = [profile for profile in imds_profiles if profile.startswith(f"{group}-")]
        if len(winners) != 1:
            raise ProfileError(
                f"IMDS must contain exactly one winner for profile group {group}"
            )
        winner = winners[0]
        if winner not in supported:
            raise ProfileError(f"workload does not support selected profile: {winner}")
        selected.append(winner)
    return selected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--file", type=Path, default=Path("/mnt/docker/docker-compose.yaml")
    )
    parser.add_argument(
        "--profiles-file", type=Path, default=Path("/mnt/pve-imds/profiles.json")
    )
    parser.add_argument("--managed-group", action="append", default=[])
    output_mode = parser.add_mutually_exclusive_group()
    output_mode.add_argument("--validate", action="store_true")
    output_mode.add_argument("--detect", action="store_true")
    output_mode.add_argument("--list-groups", action="store_true")
    args = parser.parse_args()

    try:
        model = load_compose(args.file)
        if args.validate:
            compose_profiles(model)
            return 0
        if args.managed_group and not (args.detect or args.list_groups):
            raise ProfileError(
                "--managed-group is valid only with --detect or --list-groups"
            )
        imds_profiles = [] if args.managed_group else load_imds_profiles(args.profiles_file)
        managed_groups = set(args.managed_group) or {
            profile.split("-", 1)[0] for profile in imds_profiles
        }
        if not all(re.fullmatch(r"[a-z0-9_]+", group) for group in managed_groups):
            raise ProfileError("managed group names must be sanitized tokens")
        groups = managed_compose_profiles(model, managed_groups)
        if args.detect:
            print("true" if groups else "false")
            return 0
        if args.list_groups:
            print("\n".join(sorted(groups)))
            return 0
        selected = select_profiles(groups, imds_profiles)
    except ProfileError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(",".join(selected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())