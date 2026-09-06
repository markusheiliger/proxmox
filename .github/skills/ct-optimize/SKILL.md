---
name: ct-optimize
description: "Analyze and optimize one Proxmox CT by CTID/hostname or all repository-managed CTs when no target is supplied. Use for portable workload-aware right-sizing, movable CPU/GPU profiles, cluster hardware/capability placement, node resource pressure, Alpine guest upgrades, container/image/configuration posture, or optimization reviews. Orchestrates recon per CT and scout once for cluster evidence. Advisory only: emits lifecycle commands or copy/paste remediation prompts per issue, but never applies changes."
---

# Optimize Proxmox CT workloads

Analyze one managed CT or all managed CTs in the cluster. Combine historical utilization, deep workload inspection, and cluster-node capabilities to produce evidence-backed recommendations grouped by CT.

This skill is **strictly advisory**. It must never modify files, containers, CTs, nodes, or cluster state. Commands in the report are proposals for the operator to review and run manually.

CT movability is a hard invariant. An optimization must keep the workload functional after moving to another compatible cluster node; improved performance on one node must never become an undocumented hard dependency.

## Inputs and target selection

- `CT` is optional and may be one CTID or fully qualified hostname.
- `WINDOW` is optional and defaults to `7d`.

Resolve scope non-interactively:

1. If `CT` is supplied, resolve exactly that target through numeric `/etc/pve/lxc/<CTID>.conf` entries and cluster resources. If it is absent, ambiguous, or nonexistent, stop and report the problem. Never select a substitute.
2. If `CT` is omitted, delegate cluster-wide CT discovery to the single `scout` invocation. Require Scout to enumerate numeric CTs from cluster resources, resolve every CT's owner node and hostname, and check for `/mnt/docker/<hostname>/docker-compose.yaml` on that owner node using node-safe read-only access. Use Scout's returned managed-CT inventory as the target set; do not independently build a local-only list. Never test only the current node's `/mnt/docker` tree or assume it contains another node's workload files.
3. Include stopped managed CTs. Analyze static configuration and historical evidence, but clearly mark unavailable live/runtime evidence.
4. Do not open an interactive CT selector. Do not include unmanaged CTs in cluster-wide workload optimization.

## Absolute safety contract

Only read, search, public web research, safe read-only probes, and read-only `recon`/`scout` delegation are permitted.

Never:

- Edit any repository, Compose, environment, secret, CT, Proxmox, or system file.
- Start, stop, restart, resize, upgrade, migrate, reconfigure, or otherwise mutate a CT, VM, container, service, node, storage backend, network, or device.
- Pull, build, remove, or recreate images or containers; run mutating Docker/Compose commands; install packages or scanners; load drivers; attach devices; or change permissions.
- Invoke `upgradeCT.sh`, `moveCT.sh`, `refreshCT.sh`, or any other lifecycle script, including with `--dry-run`.
- Invoke mutating `pct`, `qm`, `pvesh`, storage, package-manager, or shell-redirection operations.
- Add `--force`, answer a confirmation, or make emitted commands automatically executable.
- Read, print, transmit, or retain secret values. Report only redacted structural findings.

The prohibition applies even when the user asks to "apply," "run," or "fix" the recommendations. Explain that this skill can only prepare a manual plan.

## Portability invariant

Evaluate portability for every proposed optimization, including sizing, placement, images, profiles, devices, storage, networking, and host preparation. Classify it as exactly one of:

- **Portable** — remains functional on every otherwise-compatible node without node-specific configuration.
- **Portable with degraded fallback** — automatically falls back to a functional lower-performance mode; document the impact.
- **Blocked by missing fallback** — creates a node/device dependency with no functional fallback. Reject the optimization and emit neither an apply command nor a remediation prompt for it.
- **Unknown** — fallback or destination behavior is unverified. Do not recommend or emit an apply action until verified.

Portable accelerator stacks use generic capability profiles and rediscover hardware on every boot, refresh, and move. Follow the project contract:

- Use capability classes such as `no-discrete-gpu` and `vulkan`, never node names or durable device indices.
- Keep a functional CPU or generic fallback unless the workload already has an equally portable supported alternative.
- Let `/mnt/docker/_config/select-compose-profile.sh` select the profile/device dynamically and print exactly `profile|device`.
- Never persist `COMPOSE_PROFILES`, node identity, PCI identity, or `renderD<N>` in `.env` or Compose configuration.
- Preserve stable service endpoints across profile variants and use profile-aware lifecycle wrappers.

`ai.thesaints.home` is the canonical pattern: Ollama may select Vulkan where compatible hardware exists and automatically select the CPU profile elsewhere. Model/data storage and the service endpoint remain portable; the current node and render index are not durable identity. Treat this as an architectural example, not evidence that every workload benefits from acceleration.

Reject node-pinned CTs, GPU-only stacks without a functional fallback, hard-coded candidate nodes or device paths in workload configuration, and direct device changes that bypass profile-aware lifecycle handling.

## Required project context

Use `/root/scripts/.github/copilot-instructions.md` for host/CT path boundaries. Read the relevant canonical modules before interpreting workloads or lifecycle behavior:

- `.github/instructions/docker-compose.instructions.md`
- `.github/instructions/compose-hardware-profiles.instructions.md`
- `.github/instructions/configure-sh.instructions.md` when a target has `_config/configure.sh`
- `.github/instructions/grafana-dashboards.instructions.md` for Grafana provisioning

Treat the current script parsers and operator guides as authoritative for command syntax and effects:

- `/root/scripts/upgradeCT.sh` and `/root/scripts/upgradeCT.md`
- `/root/scripts/moveCT.sh` and `/root/scripts/moveCT.md`
- `/root/scripts/refreshCT.sh` and `/root/scripts/refreshCT.md`
- `/root/scripts/commonCT.sh` and non-secret fields in `/root/scripts/commonCT.json`

## Workflow

### 1. Establish cluster context with Scout

Invoke `scout` exactly once per optimization run. For an explicit `CT`, give Scout only the resolved identity and request cluster/node context. When `CT` is omitted, Scout is the authoritative discovery source: first obtain its complete managed-CT inventory, then use that returned set for all per-CT Recon calls and optimization output. Scout must remain cluster/node-only and must not inspect Compose contents or infer workload requirements. Ask it to return:

- A managed-CT inventory with CTID, hostname, owner node, status, and owner-local Compose-file presence. Include stopped managed CTs and separately identify unmanaged CTs excluded from workload optimization.
- Online nodes and current CT ownership.
- CPU architecture, features, topology, current pressure, and `WINDOW` historical demand where available.
- Installed memory, current pressure, and `WINDOW` historical headroom.
- Storage backend compatibility, health, free capacity, thin-pool data/metadata pressure, and workload mount availability.
- GPUs, DRM render devices, Coral/Edge TPU, PCI/USB accelerators, drivers, usable device nodes, and existing passthrough state.
- Bridge, architecture, storage, device, and migration constraints that affect candidate placement.

Scout supplies inventory and a factual node capability/capacity matrix; it does not make workload-specific placement recommendations. The parent skill later correlates this matrix with Recon's CT/workload findings. Capability placement is not generic load balancing: a destination must provide a concrete workload benefit or resolve a verified resource/capacity incompatibility.

### 2. Inspect every workload with Recon

Invoke `recon` exactly once for each selected CT. In cluster-wide mode, use bounded parallel batches so each CT retains an isolated report and failures do not discard other results.

Request Recon's standard read-only inspection plus:

- Current owner, status, CPU/RAM/rootfs allocation, guest Alpine release, mounts, network, and passthrough.
- Compose services, roles, images/tags/digests, application versions, configuration relationships, health, drift, telemetry, and bounded runtime evidence.
- Practical CPU and memory floors for applications, databases, caches, proxies, workers, and the guest OS.
- Storage use/pressure and whether rootfs growth may be necessary.
- Supported image/application upgrades, breaking changes, EOL/security posture, image variant switches, and prerequisite configuration work.
- Workload functions that could benefit from GPU, video acceleration, Coral/Edge TPU, or another node capability.
- Existing profile variants, selector behavior, stable service aliases, CPU/generic fallback, expected degradation, and any hard-coded node/device identity that would prevent movement.

Recon must remain CT/workload-only: never ask it to inventory, probe, compare, or select candidate cluster nodes. Never request raw environment, secret, certificate, credential, or token values. A failed or incomplete Recon result becomes a per-CT caveat; do not infer missing facts.

### 3. Normalize utilization evidence

For each CT, use the first source with representative coverage:

1. Aspire/Prometheus telemetry over `WINDOW`, correctly filtered to the CT/workload identity.
2. Proxmox RRD from the owning node, using both `AVERAGE` and `MAX` consolidation.
3. Current official workload minimum/recommended requirements, explicitly labeled **not telemetry-grounded**.

For telemetry record the observation interval, first/last timestamp, sample count, approximate cadence, gaps, source, and confidence. Collect where available:

- CPU sustained demand such as p50/p95, active duty cycle, and peak equivalent cores.
- Memory p50/p95 and peak bytes/percentage.
- Load, latency, throughput, swap, OOM, or pressure evidence that materially changes interpretation.
- Rootfs and application-data use and growth evidence, without treating a current snapshot as history.

For RRD, resolve the owner through `/cluster/resources`, map `WINDOW` to the smallest timeframe that covers it, parse JSON structurally, and discard null samples. RRD `cpu` is a fraction of allocation; multiply by 100 for percentage and by `maxcpu` for equivalent cores. Derive memory percentages from `mem / maxmem`.

Do not fabricate percentiles, utilization, demand, or trends from sparse data. Do not up-size from a single compute spike without corroborating sustained demand, latency, throughput, or pressure. Do not down-size without representative evidence and verified workload floors.

When telemetry is insufficient, include:

> ⚠️ This recommendation is **not grounded in representative captured telemetry**. It relies on static workload configuration and current official requirements; re-evaluate after sufficient telemetry is available.

### 4. Reconcile workload and cluster evidence

The parent skill—not either subagent—correlates each Recon workload profile with the single Scout cluster matrix:

- Separate `configured`, `running`, `observed`, `historical`, `documented`, and `inferred` facts.
- Resolve contradictory evidence conservatively and state the conflict.
- Verify current product/hardware compatibility, releases, support policy, and security claims with official sources. A mutable or old tag alone does not prove a vulnerability.
- Distinguish hardware that is present, driver-bound, exposed to the CT, selected by the Compose profile, and actually used.
- Compare Recon's fallback/profile contract with Scout's capability matrix and assign one portability classification before proposing an action.
- Never expose values from `commonCT.json`; query only required non-secret settings such as `.sizes`.

### 5. Recommend CPU and memory allocation

Read `.sizes` live from `/root/scripts/commonCT.json`; never hardcode names or values.

Choose the smallest defined size that:

- Keeps observed peak memory at approximately 80% or less, providing roughly 20% headroom.
- Accommodates sustained CPU demand while allowing justified brief peaks.
- Preserves practical application, database, cache, worker, Docker, and OS floors.
- Fits the candidate node with adequate current and historical headroom.

Prefer a defined size for predictable capacity planning. Recommend custom `--cores` and `--memory` only when no defined size reasonably fits, and explain why. Swap remains derived by `refreshCT.sh`.

Do not recommend downsizing from documentation-only or sparse evidence unless a hard configured ceiling and authoritative workload floor make it unambiguously safe; otherwise recommend collecting telemetry. Never recommend rootfs shrinking.

### 6. Recommend placement only for a verified benefit

Recommend `moveCT.sh` only when all of the following are supported by evidence:

- The destination is online and passes the current `moveCT.sh` storage, bridge, rootfs, mount, device, architecture, and migration contracts.
- It has sufficient current and `WINDOW` historical CPU/RAM/storage headroom for the recommended allocation and expected workload demand.
- It offers a concrete workload capability benefit, such as a compatible driver-ready accelerator, or resolves verified capacity/incompatibility on the current node.
- The workload version/image/profile can use the capability, or clearly identified prerequisite changes will enable it.
- Shared-device contention and fallback behavior are understood.
- The workload remains functional if later moved away from that destination; acceleration is selected dynamically and is not persisted as node identity.

Do not recommend a move solely because another node has fewer CTs or lower instantaneous load. If evidence is incomplete, report the candidate and required verification rather than emitting a move command.

### 7. Classify every issue by remediation coverage

Assign exactly one coverage class to every **actionable** recommendation:

- **Lifecycle-covered** — the complete remediation can be applied through a currently supported `upgradeCT.sh`, `moveCT.sh`, or `refreshCT.sh` invocation after its stated prerequisites are complete.
- **Uncovered** — remediation requires repository authoring, Compose/image/profile changes, telemetry wiring, authentication/configuration work, permission design, host/device preparation, or another change not directly implemented by those lifecycle commands.

Do not present the same remediation as independently complete in both classes. A plain refresh after an uncovered edit is a dependent lifecycle step, not the fix itself. Make that dependency explicit and never present the refresh as immediately runnable before the prerequisite edit is reviewed and completed. A rejected or unverified portability idea is non-actionable: mark its coverage `not applicable — portability blocked` or `not applicable — portability unknown` rather than misclassifying it as uncovered.

For each uncovered issue, emit exactly one focused copy/paste natural-language prompt. The prompt must:

- Identify the CT by hostname and CTID.
- State the desired outcome, relevant evidence, and measurable acceptance criteria.
- Require preservation of CT movability and automatic fallback where hardware is involved.
- Request a plan and explicit confirmation before edits, preserve secrets, and exclude unrelated changes.
- Be outcome-oriented rather than prescribing unverified implementation details.
- Contain one cohesive issue only and rely on natural-language skill discovery; do not name a skill.

Compose, image, service, secret, storage, health, permission, authentication, and profile requests should naturally discover `ct-compose`. Metrics, traces, OTLP, collectors, and telemetry-cleanup requests should naturally discover `ct-telemetry`. If no supported workflow covers the issue, request an implementation plan and review rather than inventing an apply mechanism.

Do not emit a remediation prompt for an optimization classified **Blocked by missing fallback** or **Unknown**. Report what evidence or architecture is missing instead.

### 8. Separate OS, workload, and configuration changes

- Recommend `upgradeCT.sh` only for an eligible outdated Alpine guest OS. Verify the current release, supported target, intermediate upgrade path, rollback behavior, and workload compatibility.
- Container image/application updates, alternate image variants, Compose edits, and hardware-profile/configuration changes are not guest OS upgrades. Describe them as separately reviewed prerequisites, followed by `refreshCT.sh` to reconcile the managed workload.
- Do not imply that `refreshCT.sh` authors prerequisite file changes. Name the files/settings that require operator review without editing them.
- Rootfs growth, unsupported passthrough, firmware/driver work, or any change not expressible through the approved lifecycle interfaces is a prerequisite/blocker, not a fabricated command.

### 9. Build safe lifecycle proposals per CT

Include only commands justified for that CT. Validate every command against the live script parser before reporting it. Never use `--force`.

Supported forms are:

```sh
cd /root/scripts && ./upgradeCT.sh <hostname> --target <VERSION>
cd /root/scripts && ./moveCT.sh <hostname> --node <NODE>
cd /root/scripts && ./refreshCT.sh <hostname> --size <DEFINED_SIZE>
cd /root/scripts && ./refreshCT.sh <hostname> --cores <N> --memory <MB>
cd /root/scripts && ./refreshCT.sh <hostname>
```

Use either `--size` or custom `--cores`/`--memory`, never both. A plain refresh is appropriate only after a separately reviewed image/config/profile prerequisite or when reconciliation itself is justified.

Order commands by actual dependencies and explain the order. A common sequence is guest OS upgrade, capability-aligned move, then refresh/resize on the destination, but do not impose it when evidence or prerequisites require another sequence. Account for each script's validation, stop/start behavior, rollback model, and downtime. Commands retain their normal interactive confirmation; this skill must not run or confirm them.

## Output contract

In all-CT mode, start with a short summary containing:

- CTs analyzed, incomplete, unchanged, and requiring review.
- Counts of lifecycle commands, uncovered prompts, portability-blocked ideas, conditional actions, incomplete inspections, and unchanged CTs.
- A risk/dependency-based operator review order.

Then emit the following complete section for **every CT**, even when unchanged:

### `<hostname>` (`<CTID>`)

**Scope and evidence**
- Current owner/status and inspection timestamp.
- Evidence source, `WINDOW`, coverage, quality, and confidence.
- Missing or conflicting evidence.

**Current → recommended**

| Area | Current | Recommended |
| --- | --- | --- |
| CPU / RAM / size | ... | ... |
| Node | ... | ... |
| Alpine guest | ... | ... |
| Workload/images/config | ... | ... |
| Hardware profile | ... | ... |

The table is an overview only. Mark blocked, conditional, and evidence-limited targets explicitly; never make them appear ready to apply.

**Portability status**
- Current profile/selector and functional fallback behavior.
- Overall classification: `portable`, `portable with degraded fallback`, `blocked by missing fallback`, or `unknown`.
- Generic capability class required, compatible destination constraints, and move blockers. Never persist a node or device identity.

**Issues and recommendations**

List issues in `critical`, `high`, `medium`, `low`, then `informational` order. Use `critical` for immediate compromise/data-loss/unavailability risk, `high` for verified material security or sustained capacity/reliability failure, `medium` for actionable maintenance or efficiency shortcomings, `low` for minor hardening/future-proofing, and `informational` for unchanged or evidence-limited observations. Use one record per distinct issue:

#### `[severity]` — `<issue title>`
- **Issue/shortcoming:** Current state and concise supporting evidence.
- **Why it matters:** Concrete security, reliability, capacity, maintainability, or portability consequence.
- **How to fix:** Desired target state and remediation approach. For a rejected optimization, state that it must not be applied.
- **Coverage:** For actionable work, exactly `lifecycle-covered — <script>` or `uncovered — <prompt intent>`. For a rejected or unverified portability idea, use `not applicable — portability blocked` or `not applicable — portability unknown`.
- **Portability impact:** Classification, automatic fallback behavior, and effect on future moves.
- **Prerequisites:** Required evidence, backup, configuration, compatibility checks, and action ordering.
- **Risk and rollback:** Likely failure modes and recovery path.
- **Downtime:** Expected service/CT interruption, or `none`/`unknown` with justification.
- **Confidence:** `high`, `medium`, or `low`, tied to evidence quality.

If there are no shortcomings, include one informational record stating that no optimization is justified. If an idea is blocked or unknown for portability, explain why and omit all apply output for that idea.

**Uncovered optimization prompts**

For every uncovered issue, emit exactly one separate `text` code block immediately labeled with the matching issue title. Prompts must be ready to copy into Copilot but must request planning and confirmation before edits. Example shape:

```text
For CT <CTID> (<hostname>), plan a focused update that <desired outcome>. Evidence: <concise evidence>. Preserve CT movability by <fallback/profile constraint>. Acceptance criteria: <verifiable result>. First inspect the current files and applicable project instructions, then present a plan and wait for explicit confirmation before editing. Preserve secrets and unrelated configuration.
```

Do not emit this subsection's prompt blocks when no uncovered issue exists. Do not wrap prompts in shell fences or make them commands.

**Lifecycle-covered actions — manual review only**

Emit exactly one `sh` code block for this CT. Include only applicable, validated lifecycle commands in dependency order. Place commands that depend on uncovered work after a comment naming the prerequisite; do not imply they are ready before that prompt's edits are complete. If no lifecycle action is justified, emit:

```sh
# No lifecycle change recommended for <hostname>.
```

Do not combine multiple CTs into a loop or batch command. Keep every CT's prompts and commands under its own report. A portability-blocked idea appears only in its issue record and never in either apply subsection.

End the complete report with:

> **Advisory only:** No files, containers, CTs, nodes, or cluster resources were changed. The commands above are proposals for manual review and execution and retain their normal validation and confirmation behavior.

## Guardrails checklist

Before returning the report, confirm:

- Scope is exactly the explicit CT or all managed CTs when omitted.
- Scout ran once, supplied cluster-wide managed-CT discovery when the target was omitted, and Recon ran once per selected CT, or failures are disclosed.
- Seven-day evidence is used by default and quality/coverage is reported.
- Sizing respects approximately 20% memory headroom, sustained CPU demand, and workload floors.
- Named sizes came from live configuration.
- Moves are workload/capability or verified-capacity driven, not generic balancing.
- Every proposed optimization is classified for portability; blocked/unknown ideas have no command or prompt.
- No node name, `COMPOSE_PROFILES`, PCI identity, or `renderD<N>` is persisted in workload configuration; hardware variants retain automatic functional fallback.
- `upgradeCT.sh` is used only for Alpine guest OS upgrades.
- Every actionable issue has exactly one remediation-coverage class. Every uncovered actionable issue has exactly one focused prompt, rejected portability ideas are explicitly non-actionable, and dependent lifecycle commands are clearly gated on completed prerequisite edits.
- No rootfs shrink or unsupported flag is proposed.
- Every issue states severity, evidence, why it matters, how to fix it, coverage, portability, prerequisites, risk/rollback, downtime, and confidence.
- Every CT has exactly one minimal lifecycle-command block; prompt blocks are one per uncovered issue.
- No command was executed, no confirmation was bypassed, no file was edited, and no secret value was exposed.
