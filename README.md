# Cluster Agent Swarm Skills

A collection of AI agent skills for orchestrating a **platform engineering swarm** — specialized AI agents that collaborate like a real team to manage Kubernetes and OpenShift clusters at scale.

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
              │   OpenShift │ EKS │ AKS │ GKE │ ROSA │
              └──────────────────────────────────────┘
```

## Quick Start

**Install the complete swarm (all agent skills):**
```bash
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills
```

**Install individual agent skills:**
```bash
# Orchestrator (coordination layer)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill orchestrator

# Cluster Operations (Atlas)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill cluster-ops

# GitOps & Deployments (Flow)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill gitops

# Security & Compliance (Shield)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill security

# Observability & Incident Response (Pulse)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill observability

# Artifact & Supply Chain (Cache)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill artifacts

# Developer Experience (Desk)
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill developer-experience
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

---

## Installation Options

### Option 1: Full Swarm (Recommended)

```bash
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills
```

### Option 2: Individual Agent Skills

```bash
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill cluster-ops
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill gitops
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill security
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill observability
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill artifacts
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill developer-experience
npx skills add https://github.com/kcns008/cluster-agent-swarm-skills --skill orchestrator
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

## Contributing

1. Fork the repository
2. Create a new skill directory: `skills/your-agent-name/`
3. Add `SKILL.md` following the agent SOUL + skill template format
4. Add scripts in `scripts/` directory
5. Submit a pull request

---

## License

MIT
