# Node-local instance metadata

## Status

The source tree contains an isolated, working proof of concept. On PVE 9.2.3
with Debian 13, the pinned execfuse revision builds against libfuse 2.9.9 and
mounts successfully. Cluster-aware deployment, immutable release staging,
systemd activation, read-only cluster verification, health checking, and
fail-closed removal are implemented under `imds/`. Production activation and
lifecycle integration remain blocked on the promotion gates below.

## Design

Each Proxmox node will run one FUSE filesystem at `/run/pve-imds`. Its root is
derived from `pvesh get /nodes/localhost/lxc --output-format json`. A managed
CT will receive only the matching `/run/pve-imds/<CTID>` directory through a
read-only bind at CT path `/mnt/pve-imds`. The guest target lives below `/mnt`
because Alpine boot cleanup removes pre-mounted children below `/run`.

Identity therefore comes from the host bind source and local Proxmox ownership,
not from a request parameter supplied by the CT. No metadata files are stored,
and no network metadata endpoint exists.

## File contract

`metadata.json` preserves the semantic JSON object from the local LXC config
API while removing these host-bound fields:

- `rootfs`
- `hookscript`
- `ssh-public-keys`
- `lxc`
- top-level `mpN`
- top-level `devN`

All other fields, including `tags`, `digest`, and `lock`, retain their Proxmox
names and JSON values. The contract follows the installed Proxmox API rather
than adding a repository schema wrapper.

`profiles.json` is produced from that redacted object with a checked-in `jq`
filter. It splits the semicolon-delimited `tags` string, accepts exact
`profile-<group>-<name>` values, removes only the `profile-` prefix, sorts the
sanitized values, and returns a JSON string array. Group and name use lowercase
alphanumeric or underscore characters. Malformed profile tags and multiple
winners for one group fail generation.

Both paths call the same API retrieval and redaction function. The profiles
hook must not open the sibling FUSE `metadata.json`, because a nested request
to the same FUSE service can deadlock. Separate opens are not transactional if
the CT configuration changes between them.

## Verified POC behavior

Automated tests currently prove:

- strict canonical CTID and local-ownership validation;
- preservation of allowed API fields and removal of the denylisted fields;
- grouped profile extraction, sanitization, sorting, and duplicate rejection;
- execfuse hook stat and NUL-delimited directory protocols;
- successful FUSE2 build and mount on PVE 9.2.3;
- dynamic root listings and exact generated file sizes;
- read-only mount enforcement and correct offset reads;
- immutable content after the first read on a descriptor;
- independent complete output for concurrent descriptors;
- host-side unprivileged reads through `allow_other`.

## Remaining gates

Before production integration:

1. Resolve the upstream execfuse license ambiguity for deployment and
   redistribution.
2. Bind one CTID directory into a disposable unprivileged CT and verify root
   and an ordinary CT user can read both files but cannot traverse to sibling
   CTIDs.
3. Test hook timeouts, output limits, daemon death, fusectl abort, forced
   unmount, restart, and stale bind behavior under systemd.
4. Exercise cluster deployment, staged upgrades, health checks, and removal on
   disposable nodes before production activation.
5. Reconcile the CT bind in create, refresh, move, rollback, delete, rename,
   and isolated backup-restore workflows.

If execfuse fails a hard gate that cannot be fixed with a small auditable
patch, use a purpose-built daemon or atomic generated files instead of
weakening CT isolation.