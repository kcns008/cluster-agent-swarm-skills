# Cluster Agent Swarm Skills

A collection of AI agent skills for orchestrating a **platform engineering swarm** — specialized AI agents that collaborate like a real team to manage Kubernetes and OpenShift clusters at scale.

![Demo](assets/demo.gif)


Skills follow the [Agent Skills](https://agentskills.io/) format.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     PLATFORM AGENT SWARM                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │   Atlas      │  │    Flow      │  │    Cache     │  │   Shield     │   │
│  │ Cluster Ops  │  │   GitOps     │  │  Artifacts   │  │  Security    │   │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘   │
│                                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────────────┐  │
│  │   Pulse      │  │    Desk      │  │         Orchestrator             │  │
│  │ Observability│  │   DevEx      │  │        (Coordinator)             │  │
│  └──────────────┘  └──────────────┘  └──────────────────────────────────┘  │
│                            │                                                │
│              ┌─────────────▼────────────────────┐                          │
│              │     Shared Platform Database      │                          │
│              │  (Clusters, Apps, Work Items)     │                          │
│              └──────────────────────────────────┘                          │
└─────────────────────────────────────────────────────────────────────────────┘
                            │
              ┌─────────────▼────────────────────────┐
              │      Your Kubernetes Clusters         │
              │   OpenShift │ ARO │ EKS │ AKS │ GKE │ ROSA │
              └──────────────────────────────────────┘
```

## Quick Start

**⚠️ Security Note: For production use, pin to a specific commit or tag rather than using main branch:**
```bash
# Clone and verify before using
git clone https://github.com/kcns008/cluster-agent-swarm-skills.git
cd cluster-agent-swarm-skills
git fetch --tags
git checkout v1.0.0  # Replace with your verified version
# Then review SKILL.md for installation
```

**Install the complete swarm (all agent skills):**
```bash
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills
```

**Install individual agent skills:**
```bash
# Using tree path (recommended)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/orchestrator

# Cluster Operations (Atlas)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/cluster-ops

# GitOps & Deployments (Flow)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/gitops

# Security & Compliance (Shield)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/security

# Observability & Incident Response (Pulse)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/observability

# Artifact & Supply Chain (Cache)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/artifacts

# Developer Experience (Desk)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/developer-experience
```

---

## Agent Roster

### 🤖 Orchestrator (Coordinator)

**The squad lead.** Coordinates work across all agents, manages task routing, runs daily standups, and ensures no work falls through the cracks.

**Use when:**
- Coordinating multi-agent workflows (deployments, incident response)
- Task assignment and routing between specialized agents
- Running daily standups and accountability checks
- Managing the shared task database and activity feed

**Skills included:**
- Task routing and agent coordination
- Daily standup generation
- Workflow orchestration (deployment pipelines, incident response)
- Cross-agent communication management
- Environment awareness (dev/qa/staging/prod)
- Continuous learning (skill improvement PRs)

**Helper scripts included:**
- `daily-standup.sh` — Generate daily standup report
- `route-task.sh` — Route a task to the appropriate agent
- `check-sla.sh` — Check for SLA breaches
- `skill-improvement-pr.sh` — Scan logs for SKILL_IMPROVEMENT and create PRs
- `setup-session.sh` — Set up environment context (dev/qa/staging/prod)
- `gather-cluster-info.sh` — Gather cluster version and component info

---

### 🏔️ Atlas — Cluster Operations Agent

**The infrastructure backbone.** Manages cluster lifecycle, node operations, upgrades, and capacity planning across OpenShift, EKS, AKS, GKE, and ROSA.

**Use when:**
- Performing cluster upgrades (OpenShift 4.x, K8s 1.31+)
- Node management: drain, cordon, scaling, GPU node pools
- etcd backup and disaster recovery
- Capacity planning and autoscaler tuning
- Network troubleshooting (OVN-Kubernetes, Cilium, Calico)
- Storage management (CSI drivers, PV/PVC issues)

**Helper scripts included:**
- `cluster-health-check.sh` — Comprehensive health assessment with scoring
- `node-maintenance.sh` — Safe node drain and maintenance prep
- `pre-upgrade-check.sh` — Pre-upgrade validation checklist
- `etcd-backup.sh` — etcd snapshot and verification
- `capacity-report.sh` — Cluster capacity and utilization report

---

### 🌊 Flow — GitOps Agent

**Git is truth.** Manages ArgoCD applications, Helm charts, Kustomize overlays, deployment strategies (canary, blue-green, rolling), and multi-cluster GitOps.

**Use when:**
- Deploying applications via ArgoCD or Flux
- Creating and managing Helm charts
- Building Kustomize overlays for multi-environment
- Implementing canary/blue-green deployment strategies
- Detecting and remediating configuration drift
- Managing multi-cluster ApplicationSets

**Helper scripts included:**
- `argocd-app-sync.sh` — ArgoCD application sync helper
- `drift-detect.sh` — Configuration drift detection
- `helm-diff.sh` — Helm release diff before upgrade
- `rollback.sh` — Safe deployment rollback
- `promote-image.sh` — Image promotion across environments

---

### 🛡️ Shield — Security Agent

**Trust nothing. Verify everything.** Handles Pod Security Standards, RBAC audits, network policies, secrets management (Vault), image scanning, and compliance (CIS, SOC2, PCI-DSS).

**Use when:**
- Auditing cluster security posture
- Implementing Pod Security Standards / Admission
- Configuring RBAC with least privilege
- Setting up NetworkPolicies for zero-trust
- Managing secrets with HashiCorp Vault
- Scanning images for CVEs (Trivy, Grype)
- Running CIS benchmark compliance checks
- Implementing Kyverno/OPA Gatekeeper policies

**Helper scripts included:**
- `security-audit.sh` — Comprehensive security posture audit
- `rbac-audit.sh` — RBAC permissions audit
- `network-policy-audit.sh` — NetworkPolicy coverage check
- `image-scan.sh` — Container image vulnerability scan
- `cis-benchmark.sh` — CIS benchmark compliance check
- `secret-rotation.sh` — Vault secret rotation helper

---

### 📊 Pulse — Observability Agent

**Signal over noise.** Manages Prometheus/Thanos metrics, Loki/ELK log aggregation, Grafana dashboards, alert tuning, SLO management, and incident response runbooks.

**Use when:**
- Investigating alert spikes (latency, error rates, CPU)
- Creating and tuning Prometheus alerts
- Building Grafana dashboards
- Defining SLOs and error budgets
- Running incident response runbooks
- Post-incident reviews and RCA
- Log analysis with Loki or Elasticsearch

**Helper scripts included:**
- `alert-triage.sh` — Alert investigation and triage
- `metric-query.sh` — PromQL query executor
- `log-search.sh` — Log aggregation search
- `slo-report.sh` — SLO compliance report
- `incident-report.sh` — Post-incident review generator

---

### 📦 Cache — Artifact Agent

**Supply chain guardian.** Manages container registries (Artifactory/JFrog), artifact promotion, vulnerability scanning, SBOM generation, and build pipeline integration.

**Use when:**
- Managing container image lifecycle
- Promoting artifacts between environments (dev → staging → prod)
- Scanning images for vulnerabilities
- Generating SBOMs (Software Bill of Materials)
- Cleaning up old artifacts and enforcing retention policies
- Integrating with CI/CD build pipelines

**Helper scripts included:**
- `promote-artifact.sh` — Artifact promotion between registries
- `scan-image.sh` — Image vulnerability scan with Trivy/Grype
- `generate-sbom.sh` — SBOM generation with Syft
- `cleanup-registry.sh` — Registry cleanup by retention policy
- `build-info.sh` — Build metadata and provenance

---

### 🎯 Desk — Developer Experience Agent

**Developer advocate.** Handles namespace provisioning, developer onboarding, pipeline debugging, common issue resolution, documentation, and self-service portal management.

**Use when:**
- Provisioning namespaces for teams
- Onboarding new developers to the platform
- Debugging common issues (CrashLoopBackOff, OOMKilled, ImagePullBackOff)
- Creating project templates and scaffolding
- Managing developer portal (Backstage)
- Platform documentation and runbooks

**Helper scripts included:**
- `provision-namespace.sh` — Namespace creation with quotas and RBAC
- `debug-pod.sh` — Common pod issue diagnosis
- `generate-manifest.sh` — Generate production-ready manifests
- `onboard-team.sh` — Team onboarding automation
- `template-app.sh` — Application scaffolding from templates

---

## Shared Infrastructure

The swarm operates on shared coordination infrastructure:

### Heartbeat Scheduling
Each agent wakes up on a staggered cron schedule (every 5-15 minutes), checks for work, takes action or reports idle, then goes back to sleep.

### Communication
Agents communicate via @mentions and thread subscriptions on shared tasks. No constant polling — notification delivery on next heartbeat.

### Shared State
All agents read/write to a shared database of clusters, applications, work items, and activity feeds. One source of truth.

### Daily Standups
An automated daily standup compiles completed work, in-progress items, blocked tasks, and items needing review.

### Human Communication & Escalation
Agents keep humans in the loop through integrated communication channels:

| Channel | Use For | Response Time |
|---------|---------|---------------|
| Slack | Non-urgent requests, status updates | < 1 hour |
| MS Teams | Non-urgent requests, status updates | < 1 hour |
| PagerDuty | Production incidents, urgent escalation | Immediate |

**Escalation Flow:**
1. Agent detects issue requiring human input
2. Send Slack/Teams message with approval request
3. Wait for response (timeout varies by priority)
4. If no response → Send reminder
5. If still no response → Trigger PagerDuty incident

**Response Timeouts:**

| Priority | Slack/Teams Wait | PagerDuty Escalation After |
|----------|------------------|---------------------------|
| CRITICAL | 3-5 minutes | 5-10 minutes total |
| HIGH | 10-15 minutes | 20-30 minutes total |
| MEDIUM | 20-30 minutes | No escalation |

All agents include Slack/MS Teams Block Kit templates for approval requests, status updates, and escalation alerts.

---

## Installation Options

### Option 1: Full Swarm (Recommended)

```bash
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills
```

### Option 2: Individual Agent Skills

```bash
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/orchestrator
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/cluster-ops
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/gitops
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/security
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/observability
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/artifacts
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills/tree/main/skills/developer-experience
```

### Option 3: Manual

```bash
git clone https://github.com/kcns008/cluster-agent-swarm-skills
cp -r skills/<agent-name> ~/.claude/skills/
```

---

## Usage

Skills are automatically available once installed. The agent activates relevant skills based on the task.

**Examples:**
```
Coordinate a canary deployment of payment-service v3.2 to prod
```
```
Atlas, investigate the CPU spike on prod-useast cluster
```
```
Shield, audit RBAC permissions for the payments namespace
```
```
Pulse, the payment API p99 latency spiked. Investigate.
```
```
Cache, promote payment-service:3.2.0 to production registry
```
```
Desk, create a namespace for the data-engineering team
```

---

## Skill Structure

Each agent skill contains:
- `SKILL.md` — Complete agent instructions with SOUL definition
- `scripts/` — Automation scripts (bash, JSON output)
- `references/` — Supporting documentation, runbooks, templates

## Command Convention

All skills use `kubectl` in examples. When working with:
- **OpenShift/ARO/ROSA clusters**: Replace `kubectl` with `oc`
- **Standard Kubernetes (AKS, EKS, GKE)**: Use `kubectl` as shown

Agents automatically detect cluster type and use the appropriate command.

## Reliability Validation

For SRE workflows, run repository checks before merging skill updates:

```bash
./scripts/validate-skills.sh
```

This validates shell syntax and core script conventions across all skill helpers,
and prints machine-readable JSON for CI/CD pipelines.

---

## Supported Platforms & Tools (February 2026)

| Category | Tool | Version |
|----------|------|---------|
| **Kubernetes** | Kubernetes | 1.31.x |
| **OpenShift** | OpenShift Container Platform | 4.17.x |
| **Managed K8s** | EKS, AKS, GKE, ARO, ROSA | Latest |
| **GitOps** | ArgoCD | 2.13.x |
| **GitOps** | Flux | 2.4.x |
| **Helm** | Helm | 3.16.x |
| **Registry** | JFrog Artifactory | 7.x |
| **Secrets** | HashiCorp Vault | 1.18.x |
| **Security** | Trivy | 0.58.x |
| **Security** | Kyverno | 1.13.x |
| **Security** | OPA Gatekeeper | 3.18.x |
| **Security** | Falco | 0.39.x |
| **Security** | kube-bench | 0.8.x |
| **Monitoring** | Prometheus / Thanos | 2.55.x / 0.37.x |
| **Logging** | Loki / Elasticsearch | 3.3.x / 8.17.x |
| **Dashboards** | Grafana | 11.x |
| **Developer** | Backstage | 1.33.x |

---

## Tracking & Observability Infrastructure

This repository includes a complete **agent memory and audit system** for swarm operations.

### File Structure

| Directory/File | Purpose |
|----------------|---------|
| `AGENTS.md` | Swarm configuration, capabilities, guardrails |
| `QUICKREF.md` | One-page reference for agent operating rules |
| `memory/MEMORY.md` | Persistent long-term learning |
| `logs/LOGS.md` | Action audit trail for all agents |
| `logs/SKILL_IMPROVEMENTS.md` | Pending skill improvements from agents |
| `incidents/INCIDENTS.md` | Production incident tracking |
| `troubleshooting/TROUBLESHOOTING.md` | Debug knowledge base |
| `agents/AGENTS.md` | Per-agent status and action logging |
| `working/SESSION.md` | Current session environment context |
| `working/WORKING.md` | Per-agent progress tracking |

### Agent Operating Rules

#### Human Approval Required (NEVER skip)
- Any deletion of resources (`kubectl delete`)
- Production environment changes
- RBAC role/rolebinding modifications
- Secret handling (create/rotate)
- Cluster-wide policy changes
- Rollback operations in production

#### Decision Classification
| Type | Action Required |
|------|-----------------|
| CRITICAL | Human must approve BEFORE execution |
| HIGH | Human must approve, can do prep work |
| MEDIUM | Human notification required |
| LOW | Agent can execute, must log |

#### Before Any Cluster Action
1. **READ** — Always read resource before modifying
2. **CHECK** — Assess impact on cluster availability
3. **LOG** — Document intent in `logs/LOGS.md`
4. **APPROVE** — Request human approval if required
5. **EXECUTE** — Apply change
6. **VERIFY** — Confirm success
7. **LOG** — Record result

#### Emergency Protocol
If something goes wrong: **STOP → ASSESS → LOG → ESCALATE → WAIT**

### Logging Requirements

Every agent action MUST be logged to:
- `logs/LOGS.md` — Action audit trail
- `agents/AGENTS.md` — Agent status update
- `incidents/INCIDENTS.md` — If failure/issue occurs
- `troubleshooting/TROUBLESHOOTING.md` — If new problem solved
- `memory/MEMORY.md` — If important learning

---

## Continuous Learning — Skill Improvements

The swarm learns from every interaction. When agents identify improvements during troubleshooting or cluster activities, they create PRs for human review.

### How It Works

1. **Agent identifies improvement** → Logs to `logs/LOGS.md` with `Category: SKILL_IMPROVEMENT`
2. **Orchestrator detects** → Scans logs on heartbeat
3. **PR created** → Human reviews the improvement
4. **Merged** → Skill updated for future agents

### Log Template

```markdown
### Agent: <agent-name>
### Category: SKILL_IMPROVEMENT
### Skill: <skill-name>/<script-or-file>
### Improvement Type: SCRIPT_FIX | NEW_CAPABILITY | REFERENCE_DOC | WORKFLOW_CHANGE
### Suggested Fix: <description>
```

### Improvement Types

| Type | Description |
|------|-------------|
| `SCRIPT_FIX` | Bug in existing script needs fixing |
| `NEW_CAPABILITY` | Script needs new feature/functionality |
| `REFERENCE_DOC` | Documentation needs updating |
| `WORKFLOW_CHANGE` | Agent workflow needs adjustment |

### Helper Script

```bash
# Scan for improvements (check-only)
bash skills/orchestrator/scripts/skill-improvement-pr.sh --check-only

# Scan and create PRs
bash skills/orchestrator/scripts/skill-improvement-pr.sh
```

---

## Environment Awareness

Every agent must know what environment they're working in and what changes are allowed.

### Environment Types

| Environment | Code | Description |
|------------|------|-------------|
| Development | `dev` | Sandbox, testing, feature development |
| QA | `qa` | Quality assurance testing |
| Staging | `staging` | Pre-production mirror |
| Production | `prod` | Live customer-facing systems |

### Change Permissions by Environment

| Action | dev | qa | staging | prod |
|--------|-----|-----|---------|------|
| **Delete Resources** | Approval | Approval | Approval | **NEVER** |
| **Modify Prod Workloads** | Approval | Approval | Approval | **NEVER** |
| **Create/Modify RBAC** | Approval | Approval | Approval | **NEVER** |
| **Scale Workloads** | Auto | Approval | Approval | **NEVER** |
| **Modify Secrets** | Approval | Approval | Approval | **NEVER** |
| **Deploy Images** | Auto | Approval | Approval | Approval Required |
| **View/Read** | Auto | Auto | Auto | Auto |

### Session Context (SESSION.md)

At session start, agents read `working/SESSION.md` to know:
- **Environment**: dev | qa | staging | prod
- **Cluster Type**: OpenShift, EKS, GKE, AKS, etc.
- **Permission Level**: What changes can be made

### Setup New Session

```bash
# Set up environment context
bash skills/orchestrator/scripts/setup-session.sh <environment> [context-name]

# Examples:
bash skills/orchestrator/scripts/setup-session.sh prod my-prod-cluster
bash skills/orchestrator/scripts/setup-session.sh dev
bash skills/orchestrator/scripts/setup-session.sh qa qa-eks-cluster
```

### Gather Cluster Information

When first connecting to a cluster:

```bash
# Gather cluster version and component info
bash skills/orchestrator/scripts/gather-cluster-info.sh

# Output JSON for automation
bash skills/orchestrator/scripts/gather-cluster-info.sh --json
```

This populates `working/SESSION.md` with:
- Platform type (OpenShift, EKS, GKE, AKS, etc.)
- Cluster version
- Kubernetes version
- Component versions (ArgoCD, Prometheus, etc.)

### Session Start Protocol

Every session MUST begin with:

```bash
# 1. Get bearings
pwd
ls -la

# 2. Read environment context (CRITICAL)
cat working/SESSION.md

# 3. Read progress file
cat working/WORKING.md

# 4. Read recent logs
cat logs/LOGS.md | head -100
```

---

## Contributing

1. Fork the repository
2. Create a new skill directory: `skills/your-agent-name/`
3. Add `SKILL.md` following the agent SOUL + skill template format
4. Add scripts in `scripts/` directory
5. Submit a pull request

---

## License

MIT
