---
name: ct-optimize
description: "Analyze and optimize one Proxmox CT by CTID/hostname or all repository-managed CTs when no target is supplied. Use for portable workload-aware right-sizing, movable CPU/GPU profiles, cluster hardware/capability placement, node resource pressure, Alpine guest upgrades, container/image/configuration posture, optimization reviews, or generating todos/optimization.md. Requires scout once per run and recon once per selected CT. Advisory only: persists a ranked report with manual lifecycle proposals and remediation prompts, but never applies recommendations."
---

# Optimize Proxmox CT workloads

Analyze one managed CT or all managed CTs in the cluster. Combine historical utilization, deep workload inspection, and cluster-node capabilities to produce evidence-backed recommendations grouped by cluster and CT.

This skill is **strictly advisory**. Its only permitted mutation is creating or replacing `/root/scripts/todos/optimization.md` with the validated report from the current run. It must never apply a recommendation or modify any other file, container, CT, node, or cluster state. Commands in the report are proposals for the operator to review and run manually.

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

Only read, search, public web research, safe read-only probes, read-only `recon`/`scout` delegation, and publication of the validated report to `/root/scripts/todos/optimization.md` are permitted.

The report is a generated output artifact, not workload configuration. Render and validate the complete document before writing it. Replace the whole file in one file-edit operation; never append, merge with, or partially update an older report. If required acquisition, reconciliation, validation, or publication fails, preserve the previous valid report and return the failure. Do not create a placeholder or incomplete file.

Never:

- Edit any repository, Compose, environment, secret, CT, Proxmox, or system file other than the single generated report path above.
- Start, stop, restart, resize, upgrade, migrate, reconfigure, or otherwise mutate a CT, VM, container, service, node, storage backend, network, or device.
- Pull, build, remove, or recreate images or containers; run mutating Docker/Compose commands; install packages or scanners; load drivers; attach devices; or change permissions.
- Invoke `upgradeCT.sh`, `moveCT.sh`, `refreshCT.sh`, or any other lifecycle script, including with `--dry-run`.
- Invoke mutating `pct`, `qm`, `pvesh`, storage, package-manager, or shell-redirection operations.
- Add `--force`, answer a confirmation, or make emitted commands automatically executable.
- Read, print, transmit, or retain secret values. Report only redacted structural findings.

The prohibition applies even when the user asks to "apply," "run," or "fix" the recommendations. Explain that this skill can only publish an advisory report and prepare manual plans.

## Portability invariant

Evaluate portability for every proposed optimization, including sizing, placement, images, profiles, devices, storage, networking, and host preparation. Classify it as exactly one of:

- **Portable** — remains functional on every otherwise-compatible node without node-specific configuration.
- **Portable with degraded fallback** — automatically falls back to a functional lower-performance mode; document the impact.
- **Blocked by missing fallback** — creates a node/device dependency with no functional fallback. Reject the optimization and emit no apply command or prompt that presents the optimization as ready. A separate evidence-backed remediation may still design and validate the missing portable fallback under the rules in section 7.
- **Unknown** — fallback or destination behavior is unverified. Do not recommend or emit an apply action until verified.

Portable accelerator stacks rediscover hardware on every boot, refresh, and move. Capability policy and ordered tests live in `commonCT.json`; workloads declare supported group-qualified values through normal service `profiles:` and provide a functional default variant. Treat `_config/select-compose-profile.sh` as a legacy workload awaiting migration; do not combine it with managed group-qualified service profiles. Never persist `COMPOSE_PROFILES`, node identity, PCI identity, or discovered device indices in `.env`. Preserve stable service endpoints across profile variants and use profile-aware lifecycle wrappers.

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

### 0. Require the acquisition agents

`scout` and `recon` are mandatory acquisition dependencies, not optional helpers.

- Before acquisition, verify that both agent types are available for model invocation. If either is unavailable, stop, explain which dependency is missing, and leave any existing optimization report unchanged. Do not replace either agent with `Explore`, direct local-only inspection, terminal probes by the parent, or inferred facts.
- Invoke `scout` exactly once per optimization run.
- Invoke `recon` exactly once for every selected CT. Do not retry a failed Recon invocation or inspect another CT as a substitute.
- If Scout fails, explicit-target resolution fails, or cluster-wide discovery is incomplete, stop the run and preserve the previous report. Scout is authoritative for cluster context and all-CT target discovery.
- After successful Scout discovery, an individual failed or incomplete Recon result becomes a disclosed incomplete per-CT section. Do not silently omit that CT or discard successful reports for other CTs.

### 0a. Discover remediation skills

After verifying acquisition-agent availability but before invoking Scout or Recon, build a remediation-owner catalog from the current workspace. Enumerate `/root/scripts/.github/skills/*/SKILL.md` and read each candidate's frontmatter `name` and `description` plus the body sections that define scope, workflow, mutation behavior, confirmation, deployment, and guardrails. Do not discover owners from user-profile, built-in, or external skills; the report must remain reproducible from this repository.

A workspace skill is eligible as a remediation owner only when its description and body contract clearly cover planning and implementing or reconciling the complete requested repository change. Exclude:

- `ct-optimize` itself.
- Read-only, advisory, acquisition, analysis, query, probe, debug, reporting, or verification-only skills.
- Skills that only gather evidence, produce recommendations, or validate another workflow's result.
- Skills whose implementation scope, exclusions, mutation/deployment behavior, or confirmation gate is absent or ambiguous.

Never infer ownership from a folder or skill name alone. Record each eligible skill's exact frontmatter name, owned domains, exclusions, confirmation contract, and deployment boundary. `ct-compose` and `ct-telemetry` are current examples of eligible remediation owners; they are not an exhaustive allowlist. `ct-probe` is a current example of an ineligible verification helper.

Future remediation skills become eligible without changing this skill when all of the following are true:

- The file is `/root/scripts/.github/skills/<name>/SKILL.md`, its YAML frontmatter is valid, and frontmatter `name` exactly matches the folder name.
- Its description contains concrete remediation verbs and domain triggers sufficient for discovery.
- Its body defines owned implementation outcomes, explicit exclusions, mutation and deployment boundaries, a plan-and-confirmation gate, and validation responsibilities.
- Its contract is specific enough to distinguish complete ownership from evidence gathering or partial assistance.

Exclude a malformed, unreadable, or underspecified candidate and record the exclusion reason in run context. Do not fail the optimization run for that exclusion; route affected work to another unambiguous complete owner or `generic`.

Match each prompt action against the catalog fail-closed:

1. If exactly one eligible skill owns the complete remediation, select its exact frontmatter name.
2. If multiple skills own separable parts of one finding, create one cohesive prompt action per owner. Parts are separable only when each action stays within one owner's contract without requiring that owner to edit another owner's domain.
3. If ownership overlaps, remains ambiguous, or no eligible skill owns the complete remediation, use `generic`; never choose the nearest description or emit duplicate competing prompts.

Keep this catalog in run context only. Do not write a registry or modify discovered skills.

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
- A complete container image evidence ledger with one row for every primary and supporting image, including verified deployed versions, authoritative release retrieval status, proposed targets, exact registry artifacts, required platforms/variants/build dependencies, and fail-closed dispositions.
- A guest OS upgrade evidence ledger with the verified installed release, authoritative supported target, exact ordered intermediate chain, per-release branch/repository availability, workload compatibility, lifecycle-parser compatibility, and a fail-closed disposition.
- Practical CPU and memory floors for applications, databases, caches, proxies, workers, and the guest OS.
- Storage use/pressure and whether rootfs growth may be necessary.
- Supported image/application upgrades, breaking changes, EOL/security posture, image variant switches, and prerequisite configuration work.
- Workload functions that could benefit from GPU, video acceleration, Coral/Edge TPU, or another node capability.
- Existing profile variants, selector behavior, stable service aliases, CPU/generic fallback, expected degradation, and any hard-coded node/device identity that would prevent movement.

Recon must remain CT/workload-only: never ask it to inventory, probe, compare, or select candidate cluster nodes. Never request raw environment, secret, certificate, credential, or token values. A failed or incomplete Recon result becomes a per-CT caveat; do not infer missing facts. Missing ledger rows or required fields are incomplete acquisition, not permission for the parent to reconstruct or synthesize them.

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
- Independently attest every actionable image and guest OS upgrade against current official release/support sources and exact deployable artifacts before publication. Record the authoritative URL, UTC retrieval timestamp, and result as exactly `verified`, `not found`, `inaccessible`, `contradictory`, or `incomplete`; tool-call completion alone is not verification.
- For an image upgrade, attest the deployed version, published stable target, exact registry manifest, required architecture/platform and variant, and every derived-build dependency. A mutable or old tag alone is neither deployed-version evidence nor proof that an upgrade exists.
- For third-party Compose remediation, recommend an explicit readable stable version tag after verification. Keep registry digests as evidence for verification, drift, provenance, and rollback rather than making digest-appended references the default. Treat the mandatory repository-controlled `caddy-stepca:latest` and `caddy-dnsimple:latest` deployment references as compliant exceptions and verify their running digest and embedded Caddy version.
- For a guest OS upgrade, attest the installed release, supported stable target, every intermediate branch/release and package repository, workload compatibility, and compatibility with the current `upgradeCT.sh` parser/path logic. Never generate a chain by numeric sequencing alone.
- For a security finding, attest that the authoritative advisory exists and is published, its affected range matches the verified deployed version, and any named fixed version has an available exact artifact. A successful lookup with a missing, empty, unrelated, or contradictory result is not advisory evidence.
- Preserve Recon's fail-closed disposition. If any required evidence is absent, stale, nonmatching, inaccessible, contradictory, or incomplete, classify the item `unverified — no recommendation`; describe the gap, omit the target and upgrade action, and do not create a prompt or command that presents the upgrade as available. Never synthesize a version, tag, digest, fixed release, advisory identifier, or OS chain from prior reports, likely numbering, or neighboring releases.
- Distinguish hardware that is present, driver-bound, exposed to the CT, selected by the Compose profile, and actually used.
- Compare Recon's fallback/profile contract with Scout's capability matrix and assign one portability classification before proposing an action.
- Never expose values from `commonCT.json`; query only required non-secret settings such as `.sizes`.

### 4a. Rank findings by relevance

Apply one deterministic relevance order to the executive review order, cluster findings, CT order in the table of contents and body, per-CT findings, and their inline actions:

1. Severity: `critical`, `high`, `medium`, `low`, then `informational`.
2. Within one severity, prerequisites and blockers before work that depends on them.
3. Then higher evidence confidence and broader security, data-loss, availability, or reliability impact.
4. Then capacity, maintainability, and operational-efficiency benefit.
5. Use CTID ascending for CT ties and normalized issue title ascending for issue ties so repeated runs remain stable.

Derive summary counts and operator review order only after sorting. Put each uncovered prompt in the same order as its matching issue. Put lifecycle commands in actual dependency order even when that requires a later-severity command to follow an earlier prerequisite. Never use alphabetical order alone as a proxy for relevance.

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

### 7. Build inline actions for every finding

Treat each finding as the report's organizing unit. An actionable finding owns one or more immediately following action records; it does not receive one issue-level coverage class. Each action has exactly one type and one owner:

- **Prompt** — repository authoring, Compose/image/profile changes, telemetry wiring, authentication/configuration work, permission design, host/device preparation, or another change not directly implemented by an approved lifecycle command. Its owner is exactly one eligible remediation skill or `generic`.
- **Lifecycle** — one currently supported `upgradeCT.sh`, `moveCT.sh`, or `refreshCT.sh` invocation. Its owner is exactly that script.

A finding may contain several prompt actions, several lifecycle actions, or both. Do not present a dependent lifecycle action as independently complete: a plain refresh after repository authoring is an application step, not the authoring fix. A rejected, unverified, unchanged, blocked, unknown, or incomplete finding is non-actionable and must instead say `**Actions:** None — <specific reason>` with no `text` or `sh` code block.

Assign every prompt action exactly one owner from the per-run remediation-owner catalog or `generic`. Use the discovered skill's complete contract, not keyword overlap alone. For example, the current catalog should assign Compose services/images, secrets, storage, health checks, permissions, authentication, initialization, and portable hardware profiles to `ct-compose`; it should assign application metrics/traces, native OTLP, Prometheus scrape sidecars, telemetry identity, duplicate-shipping prevention, migration, and stale-wiring garbage collection to `ct-telemetry`.

Use `generic` for central Telegraf or Proxmox resource telemetry, lifecycle Bash, host/storage/device preparation, and any work without one unambiguous complete owner. `ct-probe` may support a post-deploy acceptance check for unpublished HTTP endpoints but must not own remediation.

Each prompt action must stay within one owner's contract. Create separate prompt actions when a finding combines application telemetry with image, health, authentication, permission, LXC, device, or other Compose work. Do not ask `ct-compose` to reconcile application telemetry, do not ask `ct-telemetry` to perform unrelated hardening, and do not route missing central CT resource series to `ct-telemetry`.

For each prompt action, emit one focused copy/paste prompt. The prompt must:

- Contain exactly one `text` fence whose first bytes are `/plan `, with no leading whitespace, blank line, prose, or Markdown. This literal first token is what invokes the built-in Plan agent when the complete block is copied into VS Code Chat.
- Request a planning-only response. Explicitly prohibit file edits, lifecycle or apply commands, and any other implementation until the operator uses the native **Start Implementation** handoff.
- Identify the CT by hostname and CTID.
- State the desired outcome, relevant evidence, and measurable acceptance criteria.
- Require preservation of CT movability and automatic fallback where hardware is involved.
- Require the Plan agent to inspect applicable files and project instructions, resolve material ambiguities, and present an implementation-ready plan with affected files, ordered changes, dependencies, scope boundaries, and specific automated and manual verification.
- Keep the response in planning for user refinement or the native **Start Implementation** handoff. That handoff is the only transition requested by the generated prompt. Mentioning "plan," "planning-only," approval, or **Start Implementation** anywhere else in the prompt does not replace the literal leading `/plan ` token and planning-only guard.
- Preserve secrets and exclude unrelated changes.
- Be outcome-oriented rather than prescribing unverified implementation details.
- Contain one cohesive issue owned by exactly one workflow.
- Immediately after `/plan`, start skill-owned work with `Use the <skill-name> skill`, substituting the selected owner's exact discovered frontmatter name. For generic work, start with `/plan No discovered repository skill owns this complete remediation;` and request a reviewed implementation plan without inventing an owner.

Record each action's stable title, type, owner, relationship, and purpose immediately before its code block. Relationship must be exactly `independent`, `depends on <exact action title(s)>`, or `blocks <exact action title(s)>`. Every dependency title must resolve to exactly one action in the same report. Every non-generic prompt owner must exist in the current run's eligible remediation-owner catalog.

Do not emit a remediation prompt that applies an optimization classified **Blocked by missing fallback** or **Unknown**. Report what evidence or architecture is missing. When missing fallback architecture is itself a separate, evidence-backed shortcoming, create a distinct uncovered issue owned by the discovered skill whose complete contract covers portable profile authoring, currently `ct-compose`. Its prompt must design and validate generic profiles, stable endpoints, automatic CPU/generic fallback, and dynamic device discovery. Keep the original optimization blocked, and gate any later acceleration or move action on completion and validation of that separate remediation.

### 8. Separate OS, workload, and configuration changes

- Recommend `upgradeCT.sh` only when both Recon's guest OS evidence disposition and the parent's independent attestation are `upgrade verified`. Verify the installed release, supported target, every intermediate release branch and package repository, rollback behavior, workload compatibility, and current lifecycle-parser support. Otherwise report `unverified — no recommendation` and emit no OS target or command.
- Recommend a container image/application update only when both Recon's matching image evidence row and the parent's independent attestation establish `upgrade verified` for the exact target artifact and platform/variant/dependencies. Otherwise report the evidence gap without an upgrade target, prompt, or dependent refresh command.
- Container image/application updates, alternate image variants, Compose edits, and hardware-profile/configuration changes are not guest OS upgrades. Describe them as separately reviewed prerequisites, followed by `refreshCT.sh` to reconcile the managed workload.
- Do not imply that `refreshCT.sh` authors prerequisite file changes. Name the files/settings that require operator review without editing them.
- Rootfs growth, unsupported passthrough, firmware/driver work, or any change not expressible through the approved lifecycle interfaces is a prerequisite/blocker, not a fabricated command.

### 9. Build safe lifecycle actions per finding

Include only commands justified for that CT. Before reporting each command, read and validate it against both the current lifecycle script implementation and its matching operator guide (`refreshCT.sh` and `refreshCT.md`, `upgradeCT.sh` and `upgradeCT.md`, or `moveCT.sh` and `moveCT.md`). Validate the exact hostname or CTID target, supported flags, option exclusivity, recommended values, prerequisites, stop/start and downtime behavior, rollback semantics, and ordering. Never use `--force`.

Supported forms are:

```sh
cd /root/scripts && ./upgradeCT.sh <hostname> --target <VERSION>
cd /root/scripts && ./moveCT.sh <hostname> --node <NODE>
cd /root/scripts && ./refreshCT.sh <hostname> --size <DEFINED_SIZE>
cd /root/scripts && ./refreshCT.sh <hostname> --cores <N> --memory <MB>
cd /root/scripts && ./refreshCT.sh <hostname>
```

Use either `--size` or custom `--cores`/`--memory`, never both. A plain refresh is appropriate only after a separately reviewed image/config/profile prerequisite or when reconciliation itself is justified.

Order commands by actual dependencies and encode that order in each action's relationship metadata. A command that applies planned repository changes must say `depends on <exact prompt action title> completed and verified`; reviewing a plan alone does not satisfy the prerequisite. A command shared by several findings appears exactly once beneath the final blocking finding and names every prerequisite action. A common sequence is guest OS upgrade, capability-aligned move, then refresh/resize on the destination, but do not impose it when evidence or prerequisites require another sequence. Commands retain their normal interactive confirmation; this skill must not run or confirm them.

## Generated report contract

After all acquisition, reconciliation, sorting, and guardrail checks succeed, render one complete Markdown document and replace `/root/scripts/todos/optimization.md`. Return only a concise chat summary with the report link, scope, issue/action counts, and incomplete CTs; the file is the authoritative full result.

Every run fully replaces the prior report:

- Never merge a single-CT run into an older all-CT report and never retain stale CT sections.
- Never append historical generations. Version history belongs to source control.
- Include a UTC ISO 8601 generation timestamp, requested `WINDOW`, exact scope, and acquisition completeness.
- For explicit-CT scope, state that the report contains one CT and relevant cluster context only and is not a fleet-wide assessment.
- If the report path does not exist, create it only after the complete document passes validation.
- If publication fails, preserve the previous report when possible and return the complete report in chat together with the error.

Use this top-level document structure and heading order:

```markdown
# Proxmox CT Optimization Report

**Generated:** <UTC ISO 8601 timestamp>
**Window:** <WINDOW>
**Scope:** <all managed CTs | hostname (CTID)>
**Inspection completeness:** <complete | N incomplete CT inspections>

## Table of contents
- [Executive summary](#executive-summary)
- [Cluster-wide improvements](#cluster-wide-improvements)
- [CT reports](#ct-reports)
	- [<hostname> (<CTID>)](#ct-<CTID>)

<a id="executive-summary"></a>
## Executive summary

<a id="cluster-wide-improvements"></a>
## Cluster-wide improvements

<a id="ct-reports"></a>
## CT reports

<a id="ct-<CTID>"></a>
### `<hostname>` (`<CTID>`)
```

Use explicit lowercase anchors exactly as shown. The table of contents must contain the executive summary and cluster section once, followed by exactly one entry for every selected CT. CT entries and CT body sections must have identical relevance order. Prefer the highest-severity actionable issue and its dependency position when ranking CTs; use CTID ascending as the stable tie-breaker. Include incomplete and unchanged CTs.

### Executive summary

In all-CT mode include:

- CTs analyzed, incomplete, unchanged, and requiring review.
- Counts by finding severity plus inline prompt actions by owner, lifecycle actions by script, mixed-action findings, cluster actions, portability-blocked ideas, conditional actions, incomplete inspections, and unchanged CTs.
- Remediation owners actually used, plus any ineligible workspace skill whose exclusion forced an otherwise actionable issue to `generic`.
- A risk/dependency-based operator review order matching the sorted body.

In explicit-CT mode provide equivalent counts for that CT and label the cluster context as partial.

### Cluster-wide improvements

In all-CT mode, correlate Scout facts and recurring Recon findings into ordered cluster improvements. Cover systemic node/storage/network/device risks, verified capacity or pressure constraints, common configuration or maintenance debt, shared prerequisites, and cross-CT dependencies. In explicit-CT mode, include only cluster facts that materially affect that CT and begin with:

> **Partial cluster context:** This section contains only cluster evidence relevant to the selected CT and is not a fleet-wide assessment.

Do not copy every CT issue into this section. For a repeated pattern, summarize it once, list the affected CTs with links to `#ct-<CTID>`, and leave CT-specific evidence, prompts, and commands in those CT sections. A unique node- or cluster-level issue that does not belong to one CT uses this record:

#### `[severity]` — `<cluster issue title>`
- **Affected scope:** Nodes, storage, network, devices, or linked CTs.
- **Issue/shortcoming:** Current state and concise supporting evidence.
- **Why it matters:** Concrete security, reliability, capacity, maintainability, or portability consequence.
- **How to fix:** Desired target state and advisory remediation approach.
- **Portability impact:** Classification and effect on current or future placement.
- **Prerequisites and dependencies:** Required evidence, backup, compatibility checks, and action ordering.
- **Risk and rollback:** Likely failure modes and recovery path.
- **Downtime:** Expected interruption, or `none`/`unknown` with justification.
- **Confidence:** `high`, `medium`, or `low`, tied to evidence quality.

Immediately after each unique cluster finding, emit its inline actions using the same action-record format as CT findings. Cluster actions may be prompts but never shell commands. Each prompt must name the cluster or node and affected CTs and require the same implementation-ready, refinable Plan-agent output and **Start Implementation** handoff as CT prompts. Preserve secrets and movability, exclude unrelated changes, and do not add a second cluster prompt for a repeated issue already covered by per-CT actions.

If no cluster improvement is justified, include one informational record saying so. If Scout evidence is missing, the run must already have stopped before publication.

### CT reports

Emit the following complete section for **every selected CT**, even when unchanged or incomplete:

<a id="ct-<CTID>"></a>
### `<hostname>` (`<CTID>`)

**Scope and evidence**
- Current owner/status and inspection timestamp.
- Evidence source, `WINDOW`, coverage, quality, and confidence.
- Missing or conflicting evidence.

**Container image evidence**

| Image | Verified deployed version | Authoritative source / retrieval result | Verified stable target | Artifact, platform, variant, and dependency attestation | Disposition |
| --- | --- | --- | --- | --- | --- |

Include one row for every primary and supporting image. The parent disposition must be no more permissive than Recon's disposition.

**Guest OS upgrade evidence**

| Verified installed release | Authoritative source / retrieval result | Verified supported target | Intermediate release/repository attestation | Workload/parser compatibility | Disposition |
| --- | --- | --- | --- | --- | --- |

Use exactly one row. An incomplete chain must be `unverified — no recommendation` and must not name an inferred target.

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

List issues using the shared deterministic relevance order. Use `critical` for immediate compromise/data-loss/unavailability risk, `high` for verified material security or sustained capacity/reliability failure, `medium` for actionable maintenance or efficiency shortcomings, `low` for minor hardening/future-proofing, and `informational` for unchanged or evidence-limited observations. Use one record per distinct issue:

#### `[severity]` — `<issue title>`
- **Issue/shortcoming:** Current state and concise supporting evidence.
- **Why it matters:** Concrete security, reliability, capacity, maintainability, or portability consequence.
- **How to fix:** Desired target state and remediation approach. For a rejected optimization, state that it must not be applied.
- **Portability impact:** Classification, automatic fallback behavior, and effect on future moves.
- **Prerequisites:** Required evidence, backup, configuration, compatibility checks, and action ordering.
- **Risk and rollback:** Likely failure modes and recovery path.
- **Downtime:** Expected service/CT interruption, or `none`/`unknown` with justification.
- **Confidence:** `high`, `medium`, or `low`, tied to evidence quality.

Immediately after the finding fields, emit `**Actions:**` and one or more action records. Each record must be adjacent to its finding and use this metadata in order:

- `##### Action: <stable unique title>`
- `- **Type:** prompt | lifecycle`
- `- **Owner:** <eligible-skill-name> | generic | refreshCT.sh | upgradeCT.sh | moveCT.sh`
- `- **Relationship:** independent | depends on <exact action title(s)> | blocks <exact action title(s)>`
- `- **Purpose:** <one cohesive outcome and scope>`

A prompt action is followed immediately by one `text` block. It must be ready to copy into VS Code Chat, begin with `/plan`, explicitly invoke its declared owner, and produce planning content only until the operator uses the native **Start Implementation** handoff. Example shape:

```text
/plan Use the <skill-name> skill for CT <CTID> (<hostname>) to plan a focused update that <desired outcome>. Evidence: <concise evidence>. Preserve CT movability by <fallback/profile constraint>. Acceptance criteria: <verifiable result>. Inspect the current files and applicable project instructions, resolve material ambiguities, then present an implementation-ready plan with affected files, ordered changes, dependencies, scope boundaries, and specific automated and manual verification. Return planning content only; do not edit files, run lifecycle or apply commands, or begin implementation. Remain in planning so I can refine the plan or use the native Start Implementation handoff. Preserve secrets and unrelated configuration.
```

For `generic`, replace the opening with: `/plan No discovered repository skill owns this complete remediation; plan a focused implementation for ...` and retain the same implementation-ready plan and handoff requirements. Do not wrap prompts in shell fences or make them commands.

A lifecycle action is followed immediately by one `sh` block containing exactly one validated command. Its relationship names all prerequisites and, for authoring prerequisites, says they must be completed and verified. Multiple actions under one finding must use relationship metadata to state whether they are independent or sequential; visual order alone is insufficient.

If there are no shortcomings, include one informational record stating that no optimization is justified and finish it with `**Actions:** None — no evidence-backed change is justified.` Blocked, unknown, unchanged, unverified, and incomplete findings use the same `**Actions:** None — <specific reason>` form and contain no action heading or code block. A portability-blocked optimization receives no action; only a distinct evidence-backed fallback-architecture finding may receive a prompt action. Do not combine multiple CTs into a loop or batch command, and do not duplicate a lifecycle command under several findings.

End the complete report with a truthful write-status disclaimer:

> **Advisory only:** This generated report was the only file created or replaced. No recommendation was applied, and no workload file, secret, container, CT, node, or cluster resource was changed. The commands above are proposals for manual review and execution and retain their normal validation and confirmation behavior.

### Publication

Before writing, assemble and validate the entire document in memory. Check counts, anchors, ordering, inline-action adjacency, unique action titles, dependency resolution, ownership, lifecycle syntax against both script and guide, secret redaction, and the final disclaimer. Parse every action record independently. Every `Type: prompt` action must have exactly one `text` fence, no `sh` fence, and content beginning at byte zero with `/plan ` followed immediately by the owner-specific prefix. It must also contain the planning-only prohibition and native **Start Implementation** handoff. Every lifecycle action must have exactly one `sh` fence and no `text` fence. The number of valid `/plan ` prompt fences must equal the number of prompt action records; a global substring or line count is not sufficient. Reject publication and preserve the previous report if any check fails. Then create or replace only `/root/scripts/todos/optimization.md` in one file-edit operation. Never publish incrementally.

After successful publication, return a concise summary and link to `[todos/optimization.md](todos/optimization.md)`. If publication fails, report the error and provide the complete Markdown in chat without claiming the file was updated.

## Guardrails checklist

Before returning the report, confirm:

- Scope is exactly the explicit CT or all managed CTs when omitted.
- The remediation-owner catalog was rebuilt from current workspace skills for this run; every non-generic owner in coverage and prompt text exists in that eligible catalog, and no excluded advisory, read-only, diagnostic, or verification-only skill owns remediation.
- Ambiguous ownership was split only when domains were cleanly separable; otherwise it fell back to `generic` without nearest-description guessing or duplicate competing prompts.
- Both mandatory agent types were available; Scout ran exactly once and supplied cluster-wide managed-CT discovery when the target was omitted; Recon ran exactly once per selected CT, and individual Recon failures are disclosed.
- Every complete Recon result contains one image evidence row per primary/supporting image and one guest OS evidence row; missing rows or fields remain disclosed incomplete evidence and were not reconstructed by the parent.
- An unavailable agent, failed Scout, unresolved explicit target, or incomplete authoritative discovery stopped before publication and preserved the prior valid report.
- Seven-day evidence is used by default and quality/coverage is reported.
- Sizing respects approximately 20% memory headroom, sustained CPU demand, and workload floors.
- Named sizes came from live configuration.
- Moves are workload/capability or verified-capacity driven, not generic balancing.
- Every proposed optimization is classified for portability; blocked/unknown ideas have no command or apply-ready prompt, and any fallback-architecture prompt belongs to a distinct uncovered issue.
- No node name, `COMPOSE_PROFILES`, PCI identity, or `renderD<N>` is persisted in workload configuration; hardware variants retain automatic functional fallback.
- `upgradeCT.sh` is used only for Alpine guest OS upgrades.
- Every image upgrade target has matching `upgrade verified` Recon evidence and independent parent attestation for the deployed version, published stable target, exact manifest, platform/variant, and derived-build dependencies. No mutable tag, inferred version, or unavailable artifact produced a recommendation.
- Every guest OS target and each intermediate chain release/repository has matching `upgrade verified` Recon evidence and independent parent attestation, including workload and lifecycle-parser compatibility. No numerically synthesized chain produced a recommendation.
- Every actionable security upgrade is backed by an existing published authoritative advisory whose affected range matches the verified deployment and whose named fixed version has an attested exact artifact; retrieval/tool success alone was never treated as source evidence.
- Every failed, inaccessible, contradictory, nonmatching, or incomplete version/advisory/artifact/chain check is reported as `unverified — no recommendation` with no synthesized target, apply-ready prompt, lifecycle command, or blocked refresh that implies an upgrade exists.
- Every actionable finding has one or more adjacent inline actions. Every action has one type, one owner, a stable unique title, an explicit relationship, and one cohesive purpose; each prompt action has exactly one `text` fence beginning at byte zero with `/plan `, invokes the declared owner immediately after that token, and includes the planning-only and native **Start Implementation** guards. Prompt prose alone never satisfies this check. Rejected, unverified, blocked, unknown, unchanged, and incomplete findings use `**Actions:** None — <reason>` and have no code block.
- Every CT-level and unique cluster-level prompt requests affected files, ordered changes, dependencies, scope boundaries, and specific automated and manual verification; requires planning content only with no edits, lifecycle/apply commands, or implementation; and remains in planning for refinement or the native **Start Implementation** handoff.
- No rootfs shrink or unsupported flag is proposed.
- Every finding states severity, evidence, why it matters, how to fix it, portability, prerequisites, risk/rollback, downtime, confidence, and its adjacent actions or specific no-action reason.
- Every lifecycle action was validated against both the current script implementation and matching operator guide; it has exactly one command, no `--force`, no mutually exclusive resize forms, the exact CT target, and explicit completed-and-verified prompt dependencies where applicable. Shared commands appear once under the final blocking finding.
- Metadata contains UTC generation time, `WINDOW`, exact scope, and inspection completeness.
- The table of contents has exactly one cluster link and one working `#ct-<CTID>` link for every selected CT; TOC and body CT order match.
- Cluster findings and all CT findings follow the deterministic relevance order; prerequisites precede dependent actions.
- Cluster rollups link to affected CTs without duplicating their actions; unique cluster findings may have prompt actions but no shell command.
- Summary counts match the sorted findings, prompt actions by owner, lifecycle actions by script, mixed-action findings, conditional actions, incomplete CTs, and unchanged CTs.
- Application telemetry and central Telegraf/Proxmox resource telemetry are reported separately; missing central CT series never route to `ct-telemetry`.
- The complete document passed validation before one create/replace operation; no partial report was published.
- `/root/scripts/todos/optimization.md` was the only file written; no command was executed, no confirmation was bypassed, no recommendation was applied, and no secret value was exposed.
