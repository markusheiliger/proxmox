# Proxmox CT Optimization Report

**Generated:** 2026-09-06T13:45:00Z
**Window:** 7d
**Scope:** all managed CTs
**Inspection completeness:** complete acquisition; 4 CT inspections have material live-evidence gaps

## Table of contents
- [Executive summary](#executive-summary)
- [Cluster-wide improvements](#cluster-wide-improvements)
- [CT reports](#ct-reports)
	- [ca.thesaints.home (2700)](#ct-2700)
	- [webtop.thesaints.home (2000)](#ct-2000)
	- [seafile.thesaints.de (2100)](#ct-2100)
	- [home.thesaints.home (2300)](#ct-2300)
	- [mqtt.thesaints.home (2400)](#ct-2400)
	- [pdf.thesaints.home (2500)](#ct-2500)
	- [nvr.thesaints.home (2600)](#ct-2600)
	- [svr.thesaints.home (2800)](#ct-2800)
	- [dashboard.thesaints.home (2900)](#ct-2900)
	- [worker.thesaints.home (3100)](#ct-3100)
	- [desktop.thesaints.home (3200)](#ct-3200)
	- [auth.thesaints.de (3400)](#ct-3400)
	- [ai.thesaints.home (3500)](#ct-3500)
	- [nodered.thesaints.home (2200)](#ct-2200)
	- [dns.thesaints.home (3300)](#ct-3300)

<a id="executive-summary"></a>
## Executive summary

- **Fleet:** 15 managed CTs analyzed; 0 omitted; 0 unchanged; all 15 require review.
- **Acquisition:** Scout ran once and Recon ran once per selected CT. Scout discovery was complete. Live evidence was materially incomplete for CTs 2500, 2800, 3300, and 3400; CT 2500 also has a status conflict between Scout and Recon.
- **Issues:** 40 total: 1 critical, 16 high, 22 medium, and 1 low.
- **Outputs:** 35 uncovered prompts, 3 cluster prompts, 15 per-CT command blocks, 15 proposed lifecycle commands, 2 portability-blocked ideas, and 3 conditional lifecycle actions.
- **Operator review order:** follow the CT report order below: CT 2700 first, then high-severity CTs 2000, 2100, 2300, 2400, 2500, 2600, 2800, 2900, 3100, 3200, 3400, and 3500, followed by medium-only CTs 2200 and 3300. Within each CT, issues and prerequisites are already dependency ordered.
- **Placement:** no move is recommended. `pve02` has only about 17 GiB of thin-pool allocation headroom, while no workload besides CT 3500 has a verified capability benefit there. CT 3500 already owns the RTX-capable node.

<a id="cluster-wide-improvements"></a>
## Cluster-wide improvements

#### `[high]` — `pve01 DATA mirror is degraded`
- **Affected scope:** `pve01` and CT configuration trees stored on its DATA mirror.
- **Issue/shortcoming:** Scout found one mirror SSD with 750 checksum errors while the pool reports degraded.
- **Why it matters:** Additional device or integrity failure could affect configuration availability and recovery confidence.
- **How to fix:** Diagnose the device and checksum history, verify backups and scrub results, then restore a healthy redundant state before discretionary lifecycle work.
- **Coverage:** `uncovered — storage integrity remediation plan`
- **Portability impact:** Portable; remediation must preserve owner-local `/mnt/docker` and `/mnt/docker-data` contracts.
- **Prerequisites and dependencies:** Current pool status, SMART evidence, scrub results, verified backups, replacement compatibility, and an explicit maintenance plan.
- **Risk and rollback:** Replacement or resilver errors can worsen availability; retain verified backups and a documented device rollback path.
- **Downtime:** Unknown; diagnosis is online, replacement risk depends on pool state.
- **Confidence:** High, from Scout pool and device evidence.

**Prompt — pve01 DATA mirror is degraded**
```text
/plan For the Proxmox cluster, plan a focused remediation of the degraded pve01 DATA mirror affecting managed CT configuration storage. Evidence: Scout found one mirror SSD with 750 checksum errors. Acceptance criteria: current SMART and scrub evidence is reviewed, backups are verified, redundancy and pool health are restored, and all owner-local CT mount contracts remain valid. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff. Preserve secrets, CT movability, and unrelated storage.
```

#### `[medium]` — `pve01 sustained CPU scheduling pressure needs attribution`
- **Affected scope:** `pve01` and its 14 managed CTs.
- **Issue/shortcoming:** Seven-day host CPU use was modest, but CPU PSI `some` remained around 73% p50 and 75% p95.
- **Why it matters:** Scheduler contention can produce latency despite low aggregate utilization and makes naive workload placement or downsizing unsafe.
- **How to fix:** Attribute pressure to host and CT processes, validate PSI interpretation and run-queue behavior, and define alert thresholds before changing placement.
- **Coverage:** `uncovered — cluster CPU pressure investigation`
- **Portability impact:** Portable; do not pin workloads to a node solely to hide unexplained pressure.
- **Prerequisites and dependencies:** Representative per-CT CPU/run-queue telemetry and maintenance-safe read-only host profiling.
- **Risk and rollback:** Investigation is read-only; later tuning needs separate approval and baseline comparison.
- **Downtime:** None for diagnosis.
- **Confidence:** Medium; PSI is representative, attribution is absent.

**Prompt — pve01 sustained CPU scheduling pressure needs attribution**
```text
/plan For pve01 and its managed CTs, plan a read-only investigation of sustained CPU scheduling pressure. Evidence: seven-day CPU PSI some was about 73% p50 and 75% p95 despite modest aggregate CPU use. Acceptance criteria: pressure is attributed to specific host or CT activity, telemetry gaps are identified, and any proposed tuning preserves CT movability and includes measurable before/after thresholds. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff. Preserve secrets and unrelated configuration.
```

#### `[medium]` — `pve02 thin-pool headroom limits migration options`
- **Affected scope:** `pve02 local-lvm` and CTs considered for future movement.
- **Issue/shortcoming:** Only about 17 GiB remains below the lifecycle script's 80% virtual-allocation ceiling.
- **Why it matters:** Most CT rootfs migrations to `pve02` would fail validation, limiting recovery and accelerator placement choices.
- **How to fix:** Review thin-pool allocation, reclaim only verified-unused volumes, or plan capacity expansion without weakening the reserve gate.
- **Coverage:** `uncovered — thin-pool capacity plan`
- **Portability impact:** Portable; capacity work should expand compatible destinations rather than create node-specific workload assumptions.
- **Prerequisites and dependencies:** Volume inventory, backup verification, physical capacity, and rollback-safe LVM design.
- **Risk and rollback:** Incorrect reclamation can destroy data; no removal should occur without identity and backup proof.
- **Downtime:** Unknown for expansion; inventory is online.
- **Confidence:** High, from Scout LVM evidence and the current move contract.

**Prompt — pve02 thin-pool headroom limits migration options**
```text
/plan For pve02, plan a focused local-lvm capacity review. Evidence: only about 17 GiB remains below the repository's 80% virtual-allocation ceiling, blocking many CT migrations. Acceptance criteria: every volume is identified, reclaim or expansion options are ranked with rollback paths, the reserve gate remains intact, and future CT moves retain compatible storage and mount contracts. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff. Preserve secrets and unrelated storage.
```

<a id="ct-reports"></a>
## CT reports

<a id="ct-2700"></a>
### `ca.thesaints.home` (`2700`)

**Scope and evidence**
- Owner/status: `pve01`, running at 2026-09-06 inspection time.
- Evidence: static and bounded live inspection; no representative seven-day utilization series.
- Missing: rootfs trend, issuance volume, and current backup freshness. Confidence is high for permission findings and low for right-sizing.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | Retain S pending telemetry |
| Node | pve01 | Retain; no placement benefit elsewhere |
| Alpine guest | 3.24.1 | Retain; supported |
| Workload/images/config | step-ca 0.30.2 on `latest`; unsafe permissions | Protect CA state, pin reviewed release, clean stale config |
| Hardware profile | Unused broad DRM passthrough | Remove after dependency check |

**Portability status**
- CPU-only operation is functional; no selector or accelerator profile is needed.
- Overall classification: `portable`.
- Remove unused DRM exposure to reduce destination constraints.

**Issues and recommendations**

#### `[critical]` — `CA key material is world accessible`
- **Issue/shortcoming:** CA configuration, private-key directories, and files are mode `777`; `.env` is mode `0644` and structurally contains secret-bearing keys.
- **Why it matters:** Any guest process can read or replace CA material, enabling trust compromise or outage.
- **How to fix:** Back up CA state, determine mapped runtime ownership, enforce least-readable files and directories, remove unused secret-bearing keys, and validate issuance and health.
- **Coverage:** `uncovered — CA secret ownership and permission repair`
- **Portability impact:** Portable when ownership is derived from service identity rather than a node.
- **Prerequisites:** Verified CA backup, UID mapping, maintenance window, and rollback copy.
- **Risk and rollback:** Incorrect ownership prevents startup; restore the backed-up modes and state if validation fails.
- **Downtime:** Brief restart expected.
- **Confidence:** High.

**Prompt — CA key material is world accessible**
```text
/plan For CT 2700 (ca.thesaints.home), plan a focused repair of CA state and secret permissions. Evidence: CA key/configuration paths are mode 777 and .env is mode 0644. Acceptance criteria: mapped service ownership is verified, private files and directories are least-readable, stale secret-bearing keys are removed safely, step-ca health and certificate issuance pass, and rollback uses a verified CA backup. Preserve CT movability, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `CA deployment has mutable identity and unnecessary device exposure`
- **Issue/shortcoming:** step-ca uses mutable `latest`, DRM is exposed but unused, and configured OTEL/Caddy/Newt remnants are inactive.
- **Why it matters:** Future refreshes are less reproducible and unnecessary device/configuration surface complicates security review.
- **How to fix:** Pin reviewed 0.30.2 evidence, remove unused DRM and stale configuration after dependency checks, and add intentional telemetry or remove inert variables.
- **Coverage:** `uncovered — reproducible CA deployment cleanup`
- **Portability impact:** Portable; removal improves portability.
- **Prerequisites:** Immutable digest verification and confirmation that no external process uses DRM or stale keys.
- **Risk and rollback:** Pinning the wrong architecture or removing a hidden dependency can stop service; retain prior digest/config.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — CA deployment has mutable identity and unnecessary device exposure**
```text
/plan For CT 2700 (ca.thesaints.home), plan a focused deployment cleanup that pins the verified step-ca 0.30.2 release, removes unused DRM and stale Caddy/Newt/OTEL configuration, and retains the existing health behavior. Acceptance criteria: the CA starts from a reviewed immutable image, no unused device is required, telemetry configuration is intentional, and certificate issuance remains valid. Preserve CT movability and secrets. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both CT 2700 prompts above.
cd /root/scripts && ./refreshCT.sh ca.thesaints.home
```

<a id="ct-2000"></a>
### `webtop.thesaints.home` (`2000`)

**Scope and evidence**
- Owner/status: `pve01`, running and backup-locked during inspection.
- Evidence: 326/336 half-hour RRD samples from 2026-08-30T13:30Z to 2026-09-06T13:00Z; CPU p95 1.27%, memory p95 230 MiB.
- Missing: historical swap series and active-session performance. Current swap was about 96% occupied.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | Retain S; investigate swap first |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Current Webtop; access and health gaps | Enforce authentication and harden runtime |
| Hardware profile | CT DRM exposed, container CPU-only | Conditional generic profile only after validation |

**Portability status**
- CPU rendering is functional on compatible nodes.
- Overall classification: `portable with degraded fallback` for a future acceleration profile; current CPU-only deployment is portable.
- Intel acceleration remains `unknown` until a generic selector and runtime verification exist.

**Issues and recommendations**

#### `[high]` — `Webtop route and runtime privilege require immediate review`
- **Issue/shortcoming:** A fresh unauthenticated HTTPS request reached Webtop with HTTP 200; the passwordless-root desktop runs in an unconfined privileged CT and Caddy can access Docker administration.
- **Why it matters:** Failed authentication enforcement or image compromise can expose an administrative desktop and broaden guest takeover impact.
- **How to fix:** Verify intended Authentik policy and bypasses, enforce authentication, then minimize CT privileges and Docker API access through staged compatibility tests.
- **Coverage:** `uncovered — Webtop access-control and privilege hardening`
- **Portability impact:** Portable if authentication and privilege policy remain hostname/service based.
- **Prerequisites:** Confirm intentional bypasses, preserve `/config`, and define rollback tests for desktop startup.
- **Risk and rollback:** Over-hardening can break desktop features; revert one tested control at a time.
- **Downtime:** Brief restarts likely.
- **Confidence:** High.

**Prompt — Webtop route and runtime privilege require immediate review**
```text
/plan For CT 2000 (webtop.thesaints.home), plan a focused access-control and runtime-hardening update. Evidence: unauthenticated HTTPS returned Webtop HTTP 200, while the passwordless-root desktop runs in a privileged unconfined CT and Caddy has Docker API access. Acceptance criteria: Authentik enforcement and intentional bypasses are proven, unauthenticated access is rejected, required desktop features still work, and privileges are minimized with rollback tests. Preserve CT movability, /config, secrets, and unrelated settings. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Swap saturation and a large core dump are unexplained`
- **Issue/shortcoming:** Current swap is about 96% occupied and `/config` contains a 217 MiB core dump; historical memory pressure and service health telemetry are absent.
- **Why it matters:** A latent crash or stale swapped pages can mask interactive instability and invalidates downsizing.
- **How to fix:** Preserve and identify the dump, correlate its timestamp with logs, measure an active session, add bounded health/telemetry, and only then decide cleanup or sizing.
- **Coverage:** `uncovered — Webtop crash and memory investigation`
- **Portability impact:** Portable.
- **Prerequisites:** Backup `/config`, redacted crash triage, and representative active-session evidence.
- **Risk and rollback:** Removing the dump before diagnosis loses evidence; retain a backup.
- **Downtime:** None for diagnosis; restart may be needed for memory validation.
- **Confidence:** High for current state, medium for cause.

**Prompt — Swap saturation and a large core dump are unexplained**
```text
/plan For CT 2000 (webtop.thesaints.home), plan a focused crash and memory investigation. Evidence: swap is about 96% occupied and /config contains a 217 MiB core dump while seven-day averages are low. Acceptance criteria: the dump is preserved and identified, relevant logs and an active desktop session are measured, health and memory telemetry cover the failure mode, and cleanup or resizing is justified by evidence. Preserve CT movability, secrets, and unrelated data. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify CT 2000 access-control and memory work.
cd /root/scripts && ./refreshCT.sh webtop.thesaints.home
```

<a id="ct-2100"></a>
### `seafile.thesaints.de` (`2100`)

**Scope and evidence**
- Owner/status: `pve01`, running.
- Evidence: complete 336-slot RRD window; memory MAX peak 63.04%, CPU MAX peak 25.93% of one core.
- Missing: exact SeaDoc patch and historical swap; current swap was about 396 MiB.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | M (2 cores / 2048 MiB) |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Newt failing; four services drifted | Repair intent, permissions, health, then reconcile |
| Hardware profile | Unused optional DRM | Remove after dependency check |

**Portability status**
- The file/database workload has no demonstrated accelerator requirement.
- Overall classification: `portable`.
- Generic CPU operation and stable service names remain functional across compatible nodes.

**Issues and recommendations**

#### `[high]` — `Newt is nonfunctional and secret files are broadly readable`
- **Issue/shortcoming:** Newt retries every three seconds with incomplete credential structure, while four raw secret files are mode `0644`.
- **Why it matters:** The tunnel provides no function, creates log/resource churn, and credentials are not CT-root-only.
- **How to fix:** Confirm tunnel intent, either provision complete credentials or remove Newt, and enforce raw-secret ownership/modes before restart.
- **Coverage:** `uncovered — Newt intent and secret delivery repair`
- **Portability impact:** Portable when tunnel identity is configuration-driven and secrets remain owner-local.
- **Prerequisites:** Confirm external tunnel dependency and back up configuration.
- **Risk and rollback:** Removing an intended tunnel can break remote access; retain prior service/config until route validation.
- **Downtime:** Brief service refresh.
- **Confidence:** High.

**Prompt — Newt is nonfunctional and secret files are broadly readable**
```text
/plan For CT 2100 (seafile.thesaints.de), plan a focused Newt and secret-delivery repair. Evidence: Newt retries every three seconds with incomplete credential structure and four raw secret files are mode 0644. Acceptance criteria: tunnel intent is confirmed, Newt is either healthy with complete protected credentials or removed, raw secret files are CT-root-only, and Seafile access remains valid. Preserve CT movability, secret values, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Allocation is below the documented Seafile baseline`
- **Issue/shortcoming:** The CT has 1 core and 1 GiB RAM, below Seafile CE's documented 2-core/2-GiB baseline; swap is materially occupied.
- **Why it matters:** Current low CPU does not remove the support and memory-headroom gap.
- **How to fix:** Resize to defined size M after resolving current configuration issues.
- **Coverage:** `lifecycle-covered — refreshCT.sh`
- **Portability impact:** Portable; M fits `pve01`, but revalidate destination capacity before any future move.
- **Prerequisites:** Complete the Newt/secret repair and verify backups.
- **Risk and rollback:** Resize restarts the CT; return to S if post-change validation fails and S remains operational.
- **Downtime:** CT restart and Compose reconciliation.
- **Confidence:** High.

#### `[medium]` — `Running drift and weak health coverage obscure service state`
- **Issue/shortcoming:** Database, Redis, Seafile, and SeaDoc hashes differ from current configuration; only MariaDB has a healthcheck and application telemetry is absent.
- **Why it matters:** A refresh could change four services at once without adequate readiness evidence.
- **How to fix:** Review drift, pin intended releases, add bounded health/telemetry, then reconcile in a backed-up maintenance window.
- **Coverage:** `uncovered — Seafile drift and health reconciliation`
- **Portability impact:** Portable.
- **Prerequisites:** Database/application backup, migration notes, and rollback digests.
- **Risk and rollback:** Schema or image changes may be irreversible; restore data and prior digests if validation fails.
- **Downtime:** Maintenance window required.
- **Confidence:** High.

**Prompt — Running drift and weak health coverage obscure service state**
```text
/plan For CT 2100 (seafile.thesaints.de), plan a focused reconciliation of the four drifted Seafile services. Evidence: MariaDB, Redis, Seafile, and SeaDoc running hashes differ from current configuration and only MariaDB has a healthcheck. Acceptance criteria: drift is explained, intended releases are pinned, backups and rollback digests exist, service-specific readiness and telemetry are verified, and data integrity passes after reconciliation. Preserve CT movability and secrets. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both uncovered CT 2100 prompts.
cd /root/scripts && ./refreshCT.sh seafile.thesaints.de --size M
```

<a id="ct-2300"></a>
### `home.thesaints.home` (`2300`)

**Scope and evidence**
- Owner/status: `pve01`, running.
- Evidence: 326/336 RRD samples; CPU p95 0.861% of one core, memory p95 246 MiB, no OOM evidence.
- Missing: definitive Compose hash comparison and custom Caddy provenance.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | Retain S pending staged evidence |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Homepage 2.1.2 on mutable tag | Upgrade to reviewed 2.2.0+ and pin |
| Hardware profile | Unused DRM, unconfined CT | Remove/tighten after compatibility test |

**Portability status**
- No workload function uses acceleration.
- Overall classification: `portable`.
- Removing DRM improves destination compatibility.

**Issues and recommendations**

#### `[high]` — `Homepage version has a verified SSRF vulnerability`
- **Issue/shortcoming:** Running Homepage 2.1.2 is in the affected range for GHSA-669x-4pg4-w24r; 2.2.0 contains the fix.
- **Why it matters:** The dashboard can be abused for server-side requests through exposed functionality.
- **How to fix:** Back up configuration, update to a reviewed fixed release, pin immutable evidence, and validate widgets, routing, Authentik, and health.
- **Coverage:** `uncovered — Homepage security update`
- **Portability impact:** Portable.
- **Prerequisites:** Configuration backup and rollback digest.
- **Risk and rollback:** Widget behavior may regress; restore the prior digest/config.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — Homepage version has a verified SSRF vulnerability**
```text
/plan For CT 2300 (home.thesaints.home), plan a focused Homepage security update from affected 2.1.2 to a reviewed fixed release at least 2.2.0. Acceptance criteria: configuration is backed up, the image is version/digest pinned, widgets and routing work, Authentik access is enforced, and health checks pass with a documented rollback digest. Preserve CT movability, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Unused privilege and mutable deployment reduce assurance`
- **Issue/shortcoming:** Both images use mutable tags, Caddy lacks a healthcheck, `.env` is `0644`, and the unconfined CT receives unused DRM.
- **Why it matters:** Refresh behavior is less reproducible and compromise impact is broader than workload needs.
- **How to fix:** Pin reviewed images, add readiness, protect configuration, and remove unnecessary DRM/unconfined policy after compatibility validation.
- **Coverage:** `uncovered — Homepage deployment hardening`
- **Portability impact:** Portable; hardening improves portability.
- **Prerequisites:** Establish Caddy provenance and test Docker-in-LXC constraints.
- **Risk and rollback:** Excessive confinement can break Docker; stage controls and retain prior CT config.
- **Downtime:** Brief restarts.
- **Confidence:** High except custom image provenance.

**Prompt — Unused privilege and mutable deployment reduce assurance**
```text
/plan For CT 2300 (home.thesaints.home), plan a focused deployment-hardening update that pins reviewed images, adds Caddy readiness, protects configuration files, and removes unused DRM or unconfined privileges where compatible. Acceptance criteria: the dashboard remains healthy and authenticated, image provenance is recorded, no accelerator dependency exists, and rollback restores prior CT and image settings. Preserve CT movability and secrets. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both CT 2300 prompts.
cd /root/scripts && ./refreshCT.sh home.thesaints.home
```

<a id="ct-2400"></a>
### `mqtt.thesaints.home` (`2400`)

**Scope and evidence**
- Owner/status: `pve01`, running.
- Evidence: static plus current cgroup evidence; no admissible seven-day series.
- Missing: exact runtime image versions, rootfs usage, and historical percentiles. Current peak memory was 725 MiB with swap use.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 2 cores / 1024 MiB / custom | Retain until representative telemetry |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Mosquitto and Portainer unmanaged | Reconstruct managed, pinned workload |
| Hardware profile | Unused DRM | Remove after dependency check |

**Portability status**
- MQTT and management services are CPU-only.
- Overall classification: `portable`, conditional on moving named-volume state into managed bind paths.
- No accelerator profile is justified.

**Issues and recommendations**

#### `[high]` — `Compose cannot reproduce the live MQTT workload`
- **Issue/shortcoming:** Mosquitto and Portainer Agent run outside Compose; Mosquitto uses an EOL Alpine 3.18 base and state resides in rootfs named volumes.
- **Why it matters:** Refresh cannot reliably preserve the broker, clients, credentials, or data; unverified old components may miss security fixes.
- **How to fix:** Inventory running versions and intent, back up broker state, author managed pinned services and repository bind storage, and validate all five clients.
- **Coverage:** `uncovered — managed MQTT workload reconstruction`
- **Portability impact:** Portable only after state and service definitions follow managed mount contracts.
- **Prerequisites:** Broker backup, listener/password-file behavior, Portainer server compatibility, and rollback images.
- **Risk and rollback:** Data or authentication migration can disconnect clients; retain named-volume backup and prior containers until validation.
- **Downtime:** Maintenance window required.
- **Confidence:** High.

**Prompt — Compose cannot reproduce the live MQTT workload**
```text
/plan For CT 2400 (mqtt.thesaints.home), plan a focused reconstruction of the managed MQTT stack. Evidence: live Mosquitto and Portainer Agent containers are absent from Compose, Mosquitto uses an EOL Alpine 3.18 base, and broker state is in rootfs named volumes. Acceptance criteria: versions and intent are identified, broker data and authentication are backed up, intended services use pinned images and repository-managed bind storage, all five clients reconnect, and rollback preserves the original volumes. Preserve CT movability and secrets. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Configured stack lacks reproducibility and service-level assurance`
- **Issue/shortcoming:** Configured images use mutable tags, healthchecks are absent, telemetry could not provide a clean seven-day series, and DRM is unused.
- **Why it matters:** Runtime state and right-sizing cannot be verified reliably.
- **How to fix:** Pin images, add broker/proxy/management readiness, repair CT-scoped telemetry, and remove unused DRM.
- **Coverage:** `uncovered — MQTT health and telemetry hardening`
- **Portability impact:** Portable.
- **Prerequisites:** Complete managed-stack reconstruction first.
- **Risk and rollback:** Health thresholds can cause restart loops; test commands manually before enabling.
- **Downtime:** Brief refresh after reconstruction.
- **Confidence:** High for configuration, low for utilization trend.

**Prompt — Configured stack lacks reproducibility and service-level assurance**
```text
/plan For CT 2400 (mqtt.thesaints.home), after the managed stack is reconstructed, plan focused readiness and telemetry coverage for Mosquitto, Caddy, and the intended management service. Acceptance criteria: reviewed images are pinned, health checks prove protocol readiness, CT-scoped metrics cover seven representative days, unused DRM is removed, and no duplicate telemetry shipping exists. Preserve CT movability, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both CT 2400 prompts, including data backup.
cd /root/scripts && ./refreshCT.sh mqtt.thesaints.home
```

<a id="ct-2500"></a>
### `pdf.thesaints.home` (`2500`)

**Scope and evidence**
- Owner/status: Scout reported `pve01`, running; Recon found no local PID and considered it likely stopped. Treat status as conflicting.
- Evidence: static and official-release research only; live Docker and seven-day telemetry unavailable.
- Missing: Alpine release, running version/digest, health, logs, storage use, and utilization. This is an incomplete CT inspection.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 2 cores / 2048 MiB / M | Retain pending representative telemetry |
| Node | pve01 | Retain |
| Alpine guest | Unknown | Identify before any OS action |
| Workload/images/config | Legacy mutable Stirling image | Review migration to pinned official 2.14.3 |
| Hardware profile | Unused DRM | Remove after live dependency check |

**Portability status**
- Standard CPU PDF processing remains functional.
- Overall classification: `portable`; any GPU idea is `unknown` and not recommended.
- No accelerator profile is justified by current evidence.

**Issues and recommendations**

#### `[high]` — `Running Stirling version and security posture are unknowable`
- **Issue/shortcoming:** The legacy `frooodle/s-pdf:latest` reference cannot establish the deployed version; current official images and settings have changed.
- **Why it matters:** Several fixed 2026 advisories may or may not apply, and an unreviewed refresh could cross a major configuration migration.
- **How to fix:** Resolve live status/version, back up configuration/database, review V2 settings, and migrate to a pinned official 2.14.3 release only after compatibility tests.
- **Coverage:** `uncovered — Stirling image and configuration migration`
- **Portability impact:** Portable with the standard CPU image.
- **Prerequisites:** Restore trustworthy live inspection, backup H2/configuration, and test OCR/templates/Auth.
- **Risk and rollback:** Setting or schema migration can fail; preserve prior image and complete state backup.
- **Downtime:** Maintenance window required.
- **Confidence:** High for configuration risk, low for deployed vulnerability applicability.

**Prompt — Running Stirling version and security posture are unknowable**
```text
/plan For CT 2500 (pdf.thesaints.home), plan a focused Stirling PDF migration only after resolving the conflicting running status and deployed version. Evidence: Compose uses legacy frooodle/s-pdf:latest while the current official release is 2.14.3 with V2 settings. Acceptance criteria: live version is proven, H2/configuration is backed up, OCR/templates/Auth behavior is tested, the official image is pinned, and rollback restores the prior state. Preserve CT movability and secrets. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Health, telemetry, and isolation evidence is incomplete`
- **Issue/shortcoming:** Neither service has a healthcheck, only Caddy tracing is configured, and broad DRM/unconfined settings appear unused.
- **Why it matters:** Service readiness and sizing cannot be established, while unnecessary privilege remains.
- **How to fix:** Add Stirling/Caddy readiness and CT-scoped metrics, then remove unused device/privilege settings after live validation.
- **Coverage:** `uncovered — PDF stack observability and isolation plan`
- **Portability impact:** Portable; removal improves portability.
- **Prerequisites:** Restore live access and complete the image migration decision.
- **Risk and rollback:** Confinement can break nested Docker; stage and retain previous CT config.
- **Downtime:** Brief restarts.
- **Confidence:** Medium.

**Prompt — Health, telemetry, and isolation evidence is incomplete**
```text
/plan For CT 2500 (pdf.thesaints.home), plan focused health, telemetry, and isolation improvements after live access is restored. Acceptance criteria: Stirling and Caddy readiness are measurable, seven representative days of CT-scoped resource data are retained, unused DRM is removed, required LXC privileges are documented, and rollback restores prior settings. Preserve CT movability, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: resolve CT 2500 status and complete both prompts with verified backups.
cd /root/scripts && ./refreshCT.sh pdf.thesaints.home
```

<a id="ct-2600"></a>
### `nvr.thesaints.home` (`2600`)

**Scope and evidence**
- Owner/status: `pve01`, running; Frigate healthy.
- Evidence: static and bounded live evidence; normalized seven-day CT telemetry was unavailable.
- Missing: representative percentiles. Current RAM was about 83% and nearly all 512 MiB swap was occupied.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | M (2 cores / 2048 MiB) |
| Node | pve01 | Retain; existing Intel device is useful |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Frigate route uses port 5000; literal credentials | Use authenticated 8971 path and protected delivery |
| Hardware profile | Hard-coded renderD128; CPU detector | Block profile optimization until portable fallback exists |

**Portability status**
- Current CPU detection is functional, but VA-API is tied to `renderD128` without a selector.
- Overall classification: `blocked by missing fallback` for an accelerator/profile optimization; ordinary operation on the current owner remains functional.
- A generic selector, stable alias, and verified CPU fallback are required before any accelerator-driven move or OpenVINO action.

**Issues and recommendations**

#### `[high]` — `Frigate is proxied through an unauthenticated admin-equivalent port`
- **Issue/shortcoming:** Caddy routes to Frigate port 5000, documented as unauthenticated/admin-equivalent, and camera/MQTT credentials are literal in YAML with broadly readable configuration.
- **Why it matters:** External access can bypass Frigate authentication and exposed configuration increases credential impact.
- **How to fix:** Back up configuration, route through authenticated port 8971, verify users/trusted proxies/integrations, and move credentials to supported protected delivery.
- **Coverage:** `uncovered — Frigate authenticated routing and secret repair`
- **Portability impact:** Portable when hostname-based routing and raw secret delivery are used.
- **Prerequisites:** Validate integrations that currently expect port 5000 and prepare rollback config.
- **Risk and rollback:** Integrations can lose access; revert route and config from backup if validation fails.
- **Downtime:** Brief Frigate/proxy restart.
- **Confidence:** High.

**Prompt — Frigate is proxied through an unauthenticated admin-equivalent port**
```text
/plan For CT 2600 (nvr.thesaints.home), plan a focused Frigate access-control and secret-delivery repair. Evidence: Caddy proxies port 5000, which is unauthenticated/admin-equivalent, and camera/MQTT credentials are literal in broadly readable configuration. Acceptance criteria: external traffic uses authenticated port 8971, users/proxy headers/integrations pass, credentials use protected supported delivery, and rollback is tested from backup. Preserve CT movability and unrelated recordings/configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[high]` — `NVR memory allocation has no safe headroom`
- **Issue/shortcoming:** About 83% of RAM is resident and nearly all swap is consumed at size S.
- **Why it matters:** Frigate has little room for camera or detector bursts and must not be downsized.
- **How to fix:** Resize to defined size M; reassess CPU after representative inference telemetry.
- **Coverage:** `lifecycle-covered — refreshCT.sh`
- **Portability impact:** Portable; M fits the current owner.
- **Prerequisites:** Complete access-control work and verify recording/config backups.
- **Risk and rollback:** Resize restarts the CT; return to S only if evidence proves stability.
- **Downtime:** CT and workload restart.
- **Confidence:** High for current pressure, medium for long-term peak.

#### `[medium]` — `Hardware optimization is blocked by missing portable selection`
- **Issue/shortcoming:** VA-API uses hard-coded `renderD128`, no profile selector exists, and OpenVINO/Coral fallback behavior is unverified.
- **Why it matters:** A move can bind the wrong device or break acceleration; enabling a detector now would create an undocumented node dependency.
- **How to fix:** Do not apply hardware optimization. First prove a generic capability selector, stable service alias, runtime backend test, and automatic CPU fallback.
- **Coverage:** `not applicable — portability blocked`
- **Portability impact:** Blocked by missing fallback.
- **Prerequisites:** Portable architecture and representative inference tests.
- **Risk and rollback:** Premature device changes can stop decode/detection; no apply output is emitted.
- **Downtime:** Unknown.
- **Confidence:** High.

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify CT 2600 authenticated routing and secret repair.
cd /root/scripts && ./refreshCT.sh nvr.thesaints.home --size M
```

<a id="ct-2800"></a>
### `svr.thesaints.home` (`2800`)

**Scope and evidence**
- Owner/status: `pve01`, running; public health endpoint returned OK.
- Evidence: static, Proxmox point sample, and public health only; seven-day series and Docker runtime unavailable.
- Missing: Alpine/Docker versions, digests, logs, storage trends, OOM/restarts. This is an incomplete CT inspection.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 2 cores / 2048 MiB / M | Retain pending seven-day evidence |
| Node | pve01 | Retain |
| Alpine guest | Unknown | Identify before OS action |
| Workload/images/config | Two custom mutable images | Establish provenance and pin |
| Hardware profile | CPU-only | Retain |

**Portability status**
- Scraper, SQLite, and proxy functions are CPU-only.
- Overall classification: `portable`.
- No accelerator requirement or node/device identity exists.

**Issues and recommendations**

#### `[high]` — `Custom workload images are not auditable or reproducible`
- **Issue/shortcoming:** Both images use mutable `latest`; deployed versions, digests, build provenance, and embedded Caddy security baseline are unavailable.
- **Why it matters:** Refresh can silently change private application behavior and security posture without a deterministic rollback.
- **How to fix:** Establish image source/version labels and SBOM/provenance, verify Caddy 2.11.4+ baseline, pin reviewed digests, and refresh only with a current backup.
- **Coverage:** `uncovered — custom image provenance and pinning`
- **Portability impact:** Portable if amd64 compatibility and stable storage paths are retained.
- **Prerequisites:** Restore current backup verification and capture current digests.
- **Risk and rollback:** Private image changes can alter database behavior; retain prior images and SQLite backup.
- **Downtime:** Brief maintenance window.
- **Confidence:** High for reproducibility gap, medium for security impact.

**Prompt — Custom workload images are not auditable or reproducible**
```text
/plan For CT 2800 (svr.thesaints.home), plan a focused provenance and release-control update for the scraper and custom Caddy images. Evidence: both use mutable latest and deployed versions/digests are unavailable; backup verification was stale. Acceptance criteria: backup freshness is restored, current and target digests are recorded, application/Caddy versions and provenance are exposed, reviewed images are pinned, and scraper health/data pass with rollback. Preserve CT movability, secrets, and unrelated data. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Operational health and secret-file posture need hardening`
- **Issue/shortcoming:** Neither service has a Compose healthcheck, `.env` is `0644`, and Caddy has Docker API access.
- **Why it matters:** Lifecycle validation cannot distinguish readiness and broadly readable configuration increases credential risk.
- **How to fix:** Add bounded readiness, protect configuration, review socket access, and gather seven representative days before resizing.
- **Coverage:** `uncovered — scraper operational hardening`
- **Portability impact:** Portable.
- **Prerequisites:** Identify service UIDs and current runtime behavior.
- **Risk and rollback:** Incorrect modes or health commands can prevent startup; stage and retain old settings.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — Operational health and secret-file posture need hardening**
```text
/plan For CT 2800 (svr.thesaints.home), plan focused operational hardening for scraper and Caddy. Acceptance criteria: service readiness is measurable, credential-bearing configuration is CT-root-only, Docker API access is minimized or justified, and seven representative days of resource telemetry are available before sizing. Preserve CT movability, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both CT 2800 prompts and a current backup.
cd /root/scripts && ./refreshCT.sh svr.thesaints.home
```

<a id="ct-2900"></a>
### `dashboard.thesaints.home` (`2900`)

**Scope and evidence**
- Owner/status: `pve01`, running; seven services had zero restarts/OOM kills.
- Evidence: 326/336 RRD samples; CPU MAX peak 7.65% of two cores, memory MAX p95 about 629 MiB.
- Missing: historical swap and exact MCP Grafana version/readiness.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 2 cores / 2048 MiB / M | Conditional S after telemetry repair and staged validation |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Six mutable tags; weak secret modes | Pin, protect, add readiness |
| Hardware profile | Unused DRM | Remove |

**Portability status**
- The observability stack is CPU-only.
- Overall classification: `portable`.
- Removing unused DRM improves destination compatibility.

**Issues and recommendations**

#### `[high]` — `Observability secrets are broadly readable`
- **Issue/shortcoming:** `.env`, `grafana.env`, and `mcp-grafana.env` are mode `0644`; `_secrets` is `0755`.
- **Why it matters:** API/database/OIDC credentials may be readable by unrelated guest processes.
- **How to fix:** Reconcile CT-root-only source modes while ensuring runtime service delivery remains readable.
- **Coverage:** `uncovered — dashboard secret permission repair`
- **Portability impact:** Portable.
- **Prerequisites:** Identify service UID delivery and preserve raw secret semantics.
- **Risk and rollback:** Incorrect source ownership can prevent startup; retain previous metadata.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — Observability secrets are broadly readable**
```text
/plan For CT 2900 (dashboard.thesaints.home), plan a focused secret-permission repair. Evidence: .env, grafana.env, and mcp-grafana.env are mode 0644 and _secrets is 0755. Acceptance criteria: source secrets are CT-root-only, each service still receives required values without disclosure, lifecycle reconciliation preserves modes, and Grafana OIDC/datasources/MCP connectivity pass. Preserve CT movability and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Observability deployment lacks deterministic releases and complete readiness`
- **Issue/shortcoming:** Six services use mutable tags, no service has a Compose healthcheck, CT Telegraf series are absent, and unconfined DRM exposure is unused.
- **Why it matters:** Updates and lifecycle validation are nondeterministic, and sizing/ingestion health is harder to prove.
- **How to fix:** Pin compatible releases, add readiness, repair CT resource telemetry without duplicate shipping, and remove unnecessary DRM/confinement exceptions.
- **Coverage:** `uncovered — dashboard release and operability hardening`
- **Portability impact:** Portable; Tempo must remain pinned and UID 10001 ownership preserved.
- **Prerequisites:** Back up Grafana/Loki/Prometheus/Tempo state and review Tempo migration boundaries.
- **Risk and rollback:** Observability schema/config changes can interrupt ingestion; retain prior images and data backups.
- **Downtime:** Staged service restarts.
- **Confidence:** High.

**Prompt — Observability deployment lacks deterministic releases and complete readiness**
```text
/plan For CT 2900 (dashboard.thesaints.home), plan a focused release and operability update. Evidence: six services use mutable tags, no Compose healthchecks exist, CT Telegraf resource series are absent, and DRM is unused. Acceptance criteria: compatible releases are pinned, readiness covers every service, telemetry labels use canonical host/container identity without duplicate shipping, Tempo ownership/migration constraints are preserved, and unused DRM is removed. Preserve CT movability, secrets, and data. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[low]` — `Defined size S appears viable only after staged validation`
- **Issue/shortcoming:** M is lightly used, but current nonzero swap and missing CT resource telemetry create residual uncertainty.
- **Why it matters:** S could reclaim capacity, but an immediate resize could expose ingestion peaks.
- **How to fix:** After repairing health/telemetry, resize to S and monitor memory, OOM, ingestion backlog, and query latency through a representative window.
- **Coverage:** `lifecycle-covered — refreshCT.sh`
- **Portability impact:** Portable.
- **Prerequisites:** Complete both uncovered prompts, verify backups, and establish rollback thresholds.
- **Risk and rollback:** Memory pressure can drop telemetry; resize back to M if thresholds trigger.
- **Downtime:** CT restart and service reconciliation.
- **Confidence:** Medium.

**Lifecycle-covered actions — manual review only**
```sh
# Conditional prerequisite: complete both prompts and verify post-fix telemetry/rollback thresholds.
cd /root/scripts && ./refreshCT.sh dashboard.thesaints.home --size S
```

<a id="ct-3100"></a>
### `worker.thesaints.home` (`3100`)

**Scope and evidence**
- Owner/status: `pve01`, running; Compose matches runtime.
- Evidence: 326/336 RRD samples; CPU p95 1.15%, memory MAX peak 247 MiB.
- Missing: historical swap/PSI/OOM and custom Caddy remote contents.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | Retain S; 512 MiB is not a defined size and swap history is absent |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | WUNS .NET 10.0.3; exposed Glances | Patch runtime, protect access, add health |
| Hardware profile | Unused DRM | Remove |

**Portability status**
- All services are CPU-only.
- Overall classification: `portable`.
- No accelerator profile is justified.

**Issues and recommendations**

#### `[high]` — `WUNS embeds a runtime missing verified security fixes`
- **Issue/shortcoming:** WUNS contains .NET/ASP.NET 10.0.3; important fixes landed in 10.0.4 and current runtime is 10.0.11.
- **Why it matters:** A worker processing remote data retains known runtime defects even without a published port.
- **How to fix:** Rebuild/release WUNS on a reviewed current 10.0 servicing runtime, pin the image, and validate scheduled work and OTLP output.
- **Coverage:** `uncovered — WUNS runtime security update`
- **Portability impact:** Portable on amd64 nodes.
- **Prerequisites:** Source/build provenance, application tests, and rollback image.
- **Risk and rollback:** Runtime behavior may change; restore prior image if jobs fail.
- **Downtime:** Brief worker restart.
- **Confidence:** High.

**Prompt — WUNS embeds a runtime missing verified security fixes**
```text
/plan For CT 3100 (worker.thesaints.home), plan a focused WUNS runtime update from embedded .NET/ASP.NET 10.0.3 to a reviewed current 10.0 servicing release. Acceptance criteria: a reproducible pinned image is built, scheduled jobs and upstream calls pass, OTLP identity remains canonical, and rollback uses the prior digest. Preserve CT movability, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[high]` — `Worker credentials and Glances access are insufficiently protected`
- **Issue/shortcoming:** Credential-bearing `.env` is `0644`, and Glances publishes port 61208 on all interfaces while also being proxied without explicit authentication.
- **Why it matters:** Guest-local credentials and host/container metadata can bypass intended TLS/auth policy.
- **How to fix:** Move credentials to protected raw delivery, remove direct publication, and explicitly require authentication or remove the UI route.
- **Coverage:** `uncovered — worker secret and Glances access hardening`
- **Portability impact:** Portable.
- **Prerequisites:** Confirm monitoring consumers and Authentik strategy.
- **Risk and rollback:** Removing the port can break consumers; inventory and retain rollback configuration.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — Worker credentials and Glances access are insufficiently protected**
```text
/plan For CT 3100 (worker.thesaints.home), plan a focused credential and Glances access repair. Evidence: credential-bearing .env is mode 0644 and Glances publishes 61208 on all interfaces while also being proxied without explicit authentication. Acceptance criteria: credentials use protected delivery, direct publication is removed unless justified, intended users authenticate through the approved route, and monitoring still works. Preserve CT movability, secrets, and unrelated settings. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Worker services lack readiness and carry unused device exposure`
- **Issue/shortcoming:** No service has a healthcheck, Caddy's remote tag changed digest, and DRM is passed through but unused.
- **Why it matters:** Lifecycle validation cannot detect failed jobs/readiness, refresh may change Caddy unexpectedly, and privilege is broader than needed.
- **How to fix:** Add progress/readiness checks, review and pin Caddy, and remove unused DRM.
- **Coverage:** `uncovered — worker health and deployment hardening`
- **Portability impact:** Portable; removal improves portability.
- **Prerequisites:** Define WUNS last-success semantics and preserve prior Caddy digest.
- **Risk and rollback:** Bad health thresholds can restart healthy scheduled work; test first.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — Worker services lack readiness and carry unused device exposure**
```text
/plan For CT 3100 (worker.thesaints.home), plan focused readiness and deployment hardening. Acceptance criteria: WUNS exposes a meaningful last-success/progress health signal, Glances and Caddy readiness are checked, the reviewed Caddy digest is pinned, unused DRM is removed, and no healthcheck causes restart loops. Preserve CT movability, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify all CT 3100 prompts.
cd /root/scripts && ./refreshCT.sh worker.thesaints.home
```

<a id="ct-3200"></a>
### `desktop.thesaints.home` (`3200`)

**Scope and evidence**
- Owner/status: `pve01`, running; zero restarts and bounded error matches.
- Evidence: 326/336 RRD samples; CPU MAX peak 1.69%, memory MAX peak 197 MiB.
- Missing: service-level memory, swap/OOM history, API version/readiness, and immutable repo digests.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | Retain S; custom 512 MiB lacks swap evidence |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Mutable RustDesk images; weak secret modes | Protect, pin, add readiness |
| Hardware profile | Unused DRM | Remove |

**Portability status**
- RustDesk server/API functions are CPU/network workloads.
- Overall classification: `portable`.
- No node/device identity is persisted.

**Issues and recommendations**

#### `[high]` — `RustDesk API credential source is broadly readable`
- **Issue/shortcoming:** `.env` containing the API token is `0644` and `_secrets` is `0755`.
- **Why it matters:** Unrelated guest processes may read control-plane credentials.
- **How to fix:** Enforce CT-root-only sources and verify runtime delivery without exposing values.
- **Coverage:** `uncovered — RustDesk secret permission repair`
- **Portability impact:** Portable.
- **Prerequisites:** Confirm service UID access and preserve the correctly protected JWT file.
- **Risk and rollback:** Incorrect ownership can prevent API startup; retain prior metadata.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — RustDesk API credential source is broadly readable**
```text
/plan For CT 3200 (desktop.thesaints.home), plan a focused RustDesk secret-permission repair. Evidence: .env containing the API token is mode 0644 and _secrets is 0755, while the JWT file is already 0600. Acceptance criteria: all secret sources are CT-root-only, hbbs/hbbr/API still receive required values, OIDC login works, and lifecycle reconciliation preserves modes. Preserve CT movability and secret values. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `RustDesk release, readiness, and isolation controls are incomplete`
- **Issue/shortcoming:** Three workload images use mutable tags, no service has a healthcheck, and unused DRM/unconfined settings broaden the CT.
- **Why it matters:** Refresh and readiness are nondeterministic despite very low resource demand.
- **How to fix:** Verify API v2.7 compatibility, pin releases/digests, add protocol/API readiness, and remove unnecessary device/privilege settings.
- **Coverage:** `uncovered — RustDesk deployment hardening`
- **Portability impact:** Portable; removal improves compatibility.
- **Prerequisites:** Preserve shared keys/JWT and current image digests.
- **Risk and rollback:** API/web-client compatibility can regress; restore prior images/config.
- **Downtime:** Brief service restarts.
- **Confidence:** High.

**Prompt — RustDesk release, readiness, and isolation controls are incomplete**
```text
/plan For CT 3200 (desktop.thesaints.home), plan a focused RustDesk deployment-hardening update. Acceptance criteria: hbbs, hbbr, and API compatibility is verified, reviewed releases/digests are pinned, protocol and API readiness checks pass, unused DRM is removed, and only required LXC privileges remain. Preserve CT movability, keys, secrets, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both CT 3200 prompts.
cd /root/scripts && ./refreshCT.sh desktop.thesaints.home
```

<a id="ct-3400"></a>
### `auth.thesaints.de` (`3400`)

**Scope and evidence**
- Owner/status: `pve01`, running.
- Evidence: static plus 326/336 RRD points and cgroup memory evidence; Docker runtime details unavailable.
- Missing: container versions/digests/logs and drift. This is an incomplete CT inspection.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 2 cores / 2048 MiB / M | Retain M; investigate memory.high events |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Authentik 2026.5.3; raw secrets 0644 | Patch Authentik and repair configuration |
| Hardware profile | Unused DRM | Remove after compatibility test |

**Portability status**
- Identity/database/proxy functions are CPU-only.
- Overall classification: `portable`.
- Removing unused DRM improves portability.

**Issues and recommendations**

#### `[high]` — `Authentik version is within verified affected ranges`
- **Issue/shortcoming:** Configured Authentik 2026.5.3 is affected by official advisories fixed in 2026.5.5; 2026.5.6 is the current compatible patch line.
- **Why it matters:** This public identity provider is a high-value security boundary.
- **How to fix:** Back up PostgreSQL and Authentik state, update server and worker together to reviewed 2026.5.6, and validate login, OIDC, workers, and rollback.
- **Coverage:** `uncovered — Authentik security update`
- **Portability impact:** Portable.
- **Prerequisites:** Database/application backup, release notes, and prior image digests.
- **Risk and rollback:** Authentication outage or migration failure; restore database and images.
- **Downtime:** Maintenance window required.
- **Confidence:** High.

**Prompt — Authentik version is within verified affected ranges**
```text
/plan For CT 3400 (auth.thesaints.de), plan a focused Authentik security update from configured 2026.5.3 to reviewed 2026.5.6, updating server and worker together. Acceptance criteria: PostgreSQL and Authentik state are backed up, login/OIDC/worker flows pass, images are pinned, and rollback restores prior database and digests. Do not cross into the backward-incompatible 2026.8 line. Preserve CT movability and secrets. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[high]` — `Current memory allocation is at its practical ceiling`
- **Issue/shortcoming:** Current memory is about 1.87 GiB, peak about 1.985 GiB, with 642 `memory.high` events at size M.
- **Why it matters:** Downsizing is unsafe and sustained reclaim may affect authentication latency or workers.
- **How to fix:** Retain M, add per-service memory/queue/database evidence, and identify whether limits, cache behavior, or workload peaks cause the events before considering L.
- **Coverage:** `uncovered — Authentik memory-pressure investigation`
- **Portability impact:** Portable; any future L allocation must fit destination headroom.
- **Prerequisites:** Representative service-level telemetry and post-patch baseline.
- **Risk and rollback:** Premature resize or tuning can destabilize identity services; investigate first.
- **Downtime:** None for diagnosis.
- **Confidence:** High for pressure, medium for cause.

**Prompt — Current memory allocation is at its practical ceiling**
```text
/plan For CT 3400 (auth.thesaints.de), plan a read-only-first investigation of memory pressure. Evidence: about 1.87 GiB current, 1.985 GiB peak, and 642 memory.high events at size M with no OOM. Acceptance criteria: pressure is attributed across Authentik, PostgreSQL, Redis, and workers after the security patch; queue/latency impact is measured; and any later size proposal preserves at least 20% headroom and CT movability. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff. Preserve secrets.
```

#### `[medium]` — `Secret, tunnel, telemetry, and isolation configuration has drift`
- **Issue/shortcoming:** Raw secret files are `0644`, Newt credentials are structurally incomplete, telemetry identity uses `oidc.thesaints.de`, supporting tags are broad, and DRM/unconfined settings are unused.
- **Why it matters:** Credential exposure, a likely dead tunnel, mislabeled telemetry, and excess privilege reduce assurance.
- **How to fix:** Protect raw secrets, confirm/remove or repair Newt, use canonical identity, pin supporting releases, add readiness, and remove unused DRM/privilege.
- **Coverage:** `uncovered — Authentik stack configuration hardening`
- **Portability impact:** Portable when canonical hostname identity and generic runtime requirements are retained.
- **Prerequisites:** Complete Authentik update first and confirm tunnel consumers.
- **Risk and rollback:** Tunnel or confinement changes can interrupt access; stage and retain prior config.
- **Downtime:** Staged restarts.
- **Confidence:** High.

**Prompt — Secret, tunnel, telemetry, and isolation configuration has drift**
```text
/plan For CT 3400 (auth.thesaints.de), after the Authentik patch, plan focused stack hardening. Acceptance criteria: raw secrets are CT-root-only, Newt is either healthy with complete protected credentials or removed, telemetry uses auth.thesaints.de/container identity, supporting images and health checks are reviewed, and unused DRM/unconfined privileges are removed where compatible. Preserve CT movability, secrets, and unrelated identity configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify all CT 3400 prompts; retain size M.
cd /root/scripts && ./refreshCT.sh auth.thesaints.de
```

<a id="ct-3500"></a>
### `ai.thesaints.home` (`3500`)

**Scope and evidence**
- Owner/status: `pve02`, running.
- Evidence: 293/336 RRD samples over 167.5 hours; CPU p95 0.024 core, memory p95 1.10 GiB, but zero LiteLLM requests.
- Missing: representative inference load; idle evidence must not drive downsizing.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 8 cores / 12288 MiB / custom | Retain until accelerated and CPU-fallback load tests exist |
| Node | pve02 | Retain; only verified RTX-capable owner |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | LiteLLM 1.99.1; mutable drift | Review 1.100.0 and pin |
| Hardware profile | Vulkan selected but Ollama CPU-only | Reject acceleration change until runtime fallback is reliable |

**Portability status**
- CPU fallback remains functional and model endpoint/state are stable.
- Overall classification: `portable with degraded fallback`.
- The proposed GPU optimization is `blocked by missing fallback` because profile selection does not react to runtime Vulkan initialization failure.

**Issues and recommendations**

#### `[high]` — `Selected Vulkan profile is ineffective and lacks runtime fallback`
- **Issue/shortcoming:** NVIDIA Vulkan is selected, but Ollama reports CPU backend and zero VRAM; the selector checks device presence, not backend readiness.
- **Why it matters:** The stack appears accelerated while using the expensive CPU fallback, and future changes could create a node/device dependency.
- **How to fix:** Do not apply a GPU optimization. First design and prove backend readiness plus automatic CPU fallback for Vulkan or reserved end-to-end CUDA support.
- **Coverage:** `not applicable — portability blocked`
- **Portability impact:** Blocked by missing fallback for the optimization; current CPU fallback remains functional.
- **Prerequisites:** Compatible userspace/driver path, positive VRAM/inference test, generic capability selector, and failure test.
- **Risk and rollback:** GPU changes can break model startup; no apply prompt or command is emitted for this idea.
- **Downtime:** Unknown.
- **Confidence:** High.

#### `[medium]` — `LiteLLM and mutable image drift need controlled review`
- **Issue/shortcoming:** LiteLLM 1.99.1 trails 1.100.0 and all mutable tags differ from registry heads.
- **Why it matters:** Refresh can change database, model, proxy, and application components together without deterministic rollback.
- **How to fix:** Back up PostgreSQL, review LiteLLM migration notes, pin compatible releases/digests, and validate OIDC, providers, models, and rollback.
- **Coverage:** `uncovered — AI stack release control`
- **Portability impact:** Portable if CPU fallback and stable endpoint/storage are preserved.
- **Prerequisites:** Database backup and current digest inventory.
- **Risk and rollback:** Database/application incompatibility; restore prior DB and images.
- **Downtime:** Maintenance window.
- **Confidence:** High.

**Prompt — LiteLLM and mutable image drift need controlled review**
```text
/plan For CT 3500 (ai.thesaints.home), plan a focused release-control update for LiteLLM and supporting images without changing hardware profiles. Evidence: LiteLLM 1.99.1 trails 1.100.0 and every mutable tag has registry drift. Acceptance criteria: PostgreSQL is backed up, compatible releases/digests are pinned, OIDC/providers/Ollama models pass, stable endpoints and CPU fallback remain functional, and rollback restores prior data/images. Preserve CT movability and secrets. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `AI stack lacks intentional telemetry and readiness`
- **Issue/shortcoming:** OTLP variables are orphaned and LiteLLM, Ollama, and Caddy lack Compose healthchecks.
- **Why it matters:** Zero-request windows and backend failures can look healthy, preventing evidence-based sizing and failover.
- **How to fix:** Add canonical LiteLLM telemetry and service/backend readiness without duplicate shipping.
- **Coverage:** `uncovered — AI telemetry and health coverage`
- **Portability impact:** Portable; checks must pass on both accelerated and CPU fallback paths.
- **Prerequisites:** Define privacy-safe metrics and backend acceptance criteria.
- **Risk and rollback:** Aggressive checks can restart model loads; test bounded probes first.
- **Downtime:** Brief service restarts.
- **Confidence:** High.

**Prompt — AI stack lacks intentional telemetry and readiness**
```text
/plan For CT 3500 (ai.thesaints.home), plan focused telemetry and readiness for LiteLLM, Ollama, and Caddy. Acceptance criteria: canonical ai.thesaints.home/container identity is exported without duplicate shipping, request and backend mode are measurable, health checks pass on CPU fallback and any future accelerator path, and failed GPU initialization is visible. Preserve CT movability, secrets, model data, and unrelated configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Small PostgreSQL state is placed on HDD-backed storage`
- **Issue/shortcoming:** The latency-sensitive 28.5 MiB PostgreSQL data directory resides under `/mnt/docker-data`.
- **Why it matters:** It gains no meaningful capacity benefit and can add avoidable database latency.
- **How to fix:** Plan a backed-up, permission-aware migration to `/mnt/docker/postgres` while preserving service identity and rollback.
- **Coverage:** `uncovered — AI database storage migration`
- **Portability impact:** Portable; both managed mount trees exist on compatible nodes.
- **Prerequisites:** Database-consistent backup, ownership mapping, free space, and maintenance window.
- **Risk and rollback:** Copy inconsistency can corrupt data; stop writers and retain source until validation.
- **Downtime:** Required for consistent migration.
- **Confidence:** High.

**Prompt — Small PostgreSQL state is placed on HDD-backed storage**
```text
/plan For CT 3500 (ai.thesaints.home), plan a focused migration of the small PostgreSQL data directory from HDD-backed /mnt/docker-data to SSD-backed /mnt/docker/postgres. Acceptance criteria: a database-consistent backup exists, ownership and permissions are correct, writers are stopped during the final copy, LiteLLM data integrity passes, and rollback retains the untouched source until acceptance. Preserve CT movability, secrets, models, and unrelated storage. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify the three CT 3500 prompts; do not alter hardware profiles or size.
cd /root/scripts && ./refreshCT.sh ai.thesaints.home
```

<a id="ct-2200"></a>
### `nodered.thesaints.home` (`2200`)

**Scope and evidence**
- Owner/status: `pve01`, running; Node-RED healthy.
- Evidence: current/lifetime cgroup and seven-day bounded logs; no valid RRD/Prometheus series.
- Missing: representative percentiles. Lifetime memory peak was 910.8 MiB with swap use, so retain S.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | Retain S |
| Node | pve01 | Retain |
| Alpine guest | 3.24.1 | Retain |
| Workload/images/config | Node-RED 5.0.4; recurring errors | Diagnose, review 5.0.6, protect HTTP inputs |
| Hardware profile | CPU-only | Retain |

**Portability status**
- Automation workload has no accelerator need.
- Overall classification: `portable`.
- Stable CPU operation and no device identity support movement.

**Issues and recommendations**

#### `[medium]` — `Recurring Node-RED errors and HTTP-input authentication need diagnosis`
- **Issue/shortcoming:** Logs contain 68 error-keyword events while health remains green; two HTTP-input flows may lack `httpNodeAuth` protection.
- **Why it matters:** A process-only healthcheck can hide broken automations, and editor authentication does not protect HTTP nodes.
- **How to fix:** Categorize errors without exposing payloads, verify each HTTP route's authentication, and add flow-level success/readiness evidence.
- **Coverage:** `uncovered — Node-RED runtime and endpoint security repair`
- **Portability impact:** Portable.
- **Prerequisites:** Backup `/data` and inventory dependent callers.
- **Risk and rollback:** Authentication changes can break integrations; stage callers and retain old flow backup.
- **Downtime:** None for diagnosis; brief restart for config.
- **Confidence:** High for errors, medium for route exposure.

**Prompt — Recurring Node-RED errors and HTTP-input authentication need diagnosis**
```text
/plan For CT 2200 (nodered.thesaints.home), plan a focused diagnosis of recurring Node-RED errors and HTTP-input access controls. Evidence: 68 error-keyword log events occurred while health stayed green, and two HTTP-input flows may not be covered by editor authentication. Acceptance criteria: errors are categorized with redacted evidence, affected flows are repaired, every HTTP route has explicit intended authentication, dependent callers pass, and /data rollback exists. Preserve CT movability, credentials, and unrelated flows. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `Node-RED release and observability controls are incomplete`
- **Issue/shortcoming:** Running 5.0.4 trails 5.0.6, Caddy provenance is unresolved, OTLP variables are inert, and Caddy lacks readiness.
- **Why it matters:** Maintenance and security posture cannot be reproduced, and sizing lacks representative evidence.
- **How to fix:** Review contributed-node compatibility, pin Node-RED 5.0.6 and a verified Caddy build, add readiness, and wire intentional telemetry or remove inert keys.
- **Coverage:** `uncovered — Node-RED release and telemetry update`
- **Portability impact:** Portable.
- **Prerequisites:** Back up `/data`, test legacy nodes, and retain rollback digests.
- **Risk and rollback:** Palette compatibility can break flows; restore data and images.
- **Downtime:** Brief maintenance window.
- **Confidence:** High.

**Prompt — Node-RED release and observability controls are incomplete**
```text
/plan For CT 2200 (nodered.thesaints.home), plan a focused release and observability update. Acceptance criteria: contributed-node compatibility is tested, Node-RED 5.0.6 and a verified Caddy build are pinned, service readiness is meaningful, telemetry is intentionally wired or inert variables are removed, and seven representative days can support later sizing. Preserve CT movability, /data, credentials, and unrelated flows. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both CT 2200 prompts.
cd /root/scripts && ./refreshCT.sh nodered.thesaints.home
```

<a id="ct-3300"></a>
### `dns.thesaints.home` (`3300`)

**Scope and evidence**
- Owner/status: `pve01`, running by Scout/current snapshot.
- Evidence: static and point-in-time Proxmox status only; no admissible seven-day series or Docker runtime.
- Missing: Alpine, image versions/digests, logs, health, drift, and utilization. This is an incomplete CT inspection.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | 1 core / 1024 MiB / S | Retain S |
| Node | pve01 | Retain |
| Alpine guest | Unknown | Identify before OS action |
| Workload/images/config | Mutable images; no healthchecks | Pin, secure Glances, make bootstrap deterministic |
| Hardware profile | Unused DRM | Remove |

**Portability status**
- DNS/proxy/monitoring is CPU-only.
- Overall classification: `portable`.
- The hard-coded upstream DNS address is a network compatibility constraint, not a hardware requirement.

**Issues and recommendations**

#### `[medium]` — `Glances exposure and CT isolation are broader than needed`
- **Issue/shortcoming:** Glances is routed without visible authentication and has Docker metadata access; the CT is unconfined with unused DRM.
- **Why it matters:** Monitoring metadata and Docker control surface may be exposed beyond intended users.
- **How to fix:** Require approved authentication or remove the UI, minimize socket access, and remove unused device/privilege settings.
- **Coverage:** `uncovered — DNS monitoring access hardening`
- **Portability impact:** Portable; removal improves portability.
- **Prerequisites:** Confirm monitoring consumers and Docker API requirements.
- **Risk and rollback:** Access changes can break operators; retain tested rollback route.
- **Downtime:** Brief refresh.
- **Confidence:** High.

**Prompt — Glances exposure and CT isolation are broader than needed**
```text
/plan For CT 3300 (dns.thesaints.home), plan a focused Glances access and isolation update. Acceptance criteria: the UI is either removed or protected by the approved authentication path, Docker API access is minimized or justified, unused DRM is removed, required LXC privileges are documented, and DNS service remains independent of the UI. Preserve CT movability, secrets, and unrelated DNS configuration. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

#### `[medium]` — `DNS deployment is mutable and bootstrap failures are nonfatal`
- **Issue/shortcoming:** All images are broad/mutable, no service has a healthcheck, telemetry covers only CoreDNS/Caddy partially, and configure bootstrap can fail without making provisioning fatal.
- **Why it matters:** A CT may appear provisioned while DNS or telemetry is unavailable, with no reproducible rollback.
- **How to fix:** Pin reviewed releases, add protocol/readiness checks, make bootstrap deterministic and fatal on required failure, clean obsolete keys, and restore CT-scoped telemetry.
- **Coverage:** `uncovered — DNS release and bootstrap reliability repair`
- **Portability impact:** Portable if canonical identity and destination network compatibility are retained.
- **Prerequisites:** Validate upstream DNS reachability and current CoreDNS behavior.
- **Risk and rollback:** Bootstrap mistakes can interrupt DNS; stage validation and retain old images/config.
- **Downtime:** Brief maintenance window.
- **Confidence:** High for static findings, low for runtime version impact.

**Prompt — DNS deployment is mutable and bootstrap failures are nonfatal**
```text
/plan For CT 3300 (dns.thesaints.home), plan a focused release and bootstrap-reliability update. Acceptance criteria: CoreDNS, Glances, Caddy, and collector releases are reviewed and pinned; DNS TCP/UDP readiness and telemetry health are checked; required configure failures are fatal and idempotent; obsolete environment keys are removed safely; and upstream DNS/network compatibility is verified. Preserve CT movability, secrets, and unrelated zones. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff.
```

**Lifecycle-covered actions — manual review only**
```sh
# Prerequisite: complete and verify both CT 3300 prompts.
cd /root/scripts && ./refreshCT.sh dns.thesaints.home
```

> **Advisory only:** This generated report was the only file created or replaced. No recommendation was applied, and no workload file, secret, container, CT, node, or cluster resource was changed. The commands above are proposals for manual review and execution and retain their normal validation and confirmation behavior.