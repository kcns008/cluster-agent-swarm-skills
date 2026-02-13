# AGENTS.md — Cluster Agent Swarm Skills

## Repository Purpose

This repository contains skills for an AI agent swarm designed to manage Kubernetes and OpenShift platform operations. Each skill directory under `skills/` represents one specialized agent in the swarm.

## The Swarm

| Agent | Code Name | Session Key | Domain |
|-------|-----------|-------------|--------|
| Orchestrator | Jarvis | `agent:platform:orchestrator` | Task routing, coordination, standups |
| Cluster Ops | Atlas | `agent:platform:cluster-ops` | Cluster lifecycle, nodes, upgrades |
| GitOps | Flow | `agent:platform:gitops` | ArgoCD, Helm, Kustomize, deploys |
| Security | Shield | `agent:platform:security` | RBAC, policies, secrets, scanning |
| Observability | Pulse | `agent:platform:observability` | Metrics, logs, alerts, incidents |
| Artifacts | Cache | `agent:platform:artifacts` | Registries, SBOM, promotion, CVEs |
| Developer Experience | Desk | `agent:platform:developer-experience` | Namespaces, onboarding, support |

## Agent Capabilities

### What Agents CAN Do
- Read cluster state (`kubectl get`, `kubectl describe`, `oc get`)
- Deploy via GitOps (`argocd app sync`, Flux reconciliation)
- Create documentation and reports
- Investigate and triage incidents
- Provision standard resources (namespaces, quotas, RBAC)
- Run health checks and audits
- Scan images and generate SBOMs
- Query metrics and logs
- Execute pre-approved runbooks

### What Agents CANNOT Do (Human-in-the-Loop Required)
- Delete production resources (`kubectl delete` in prod)
- Modify cluster-wide policies (NetworkPolicy, OPA, Kyverno cluster policies)
- Make direct changes to secrets without rotation workflow
- Modify network routes or service mesh configuration
- Scale beyond defined resource limits
- Perform irreversible cluster upgrades
- Approve production deployments (can prepare, human approves)
- Change RBAC at cluster-admin level

## Communication Patterns

### @Mentions
Agents communicate via @mentions in shared task comments:
```
@Shield Please review the RBAC for payment-service v3.2 before I sync.
@Pulse Is the CPU spike related to the deployment or external traffic?
@Atlas The staging cluster needs 2 more worker nodes.
```

### Thread Subscriptions
- Commenting on a task → auto-subscribe
- Being @mentioned → auto-subscribe
- Being assigned → auto-subscribe
- Once subscribed → receive ALL future comments on heartbeat

### Escalation Path
1. Agent detects issue
2. Agent attempts resolution within guardrails
3. If blocked → @mention another agent or escalate to human
4. P1 incidents → all relevant agents auto-notified

## Heartbeat Schedule

Agents wake on staggered 5-minute intervals:
```
*/5  * * * *  Atlas   (Cluster Ops - needs fast response for incidents)
*/5  * * * *  Pulse   (Observability - needs fast response for alerts)
*/5  * * * *  Shield  (Security - fast response for CVEs and threats)
*/10 * * * *  Flow    (GitOps - deployments can wait a few minutes)
*/10 * * * *  Cache   (Artifacts - promotions are scheduled)
*/15 * * * *  Desk    (DevEx - developer requests aren't usually urgent)
*/15 * * * *  Orchestrator (Coordination - overview and standups)
```

## File Structure Convention

```
skills/{agent-name}/
  SKILL.md              # Agent SOUL + skill definition (required)
  scripts/              # Executable bash scripts (optional)
    script-name.sh      # kebab-case, JSON output on stdout, messages on stderr
  references/           # Supporting docs, runbooks, templates (optional)
    reference-doc.md    # Additional context for the agent
```

## Script Conventions

All scripts follow these patterns:
1. **Shebang:** `#!/bin/bash`
2. **Strict mode:** `set -e`
3. **Output:** Human-readable messages to `stderr`, structured JSON to `stdout`
4. **Arguments:** Positional args with usage message if missing
5. **Platform detection:** Auto-detect OpenShift vs standard Kubernetes
6. **Exit codes:** 0 = success, 1 = error, 2 = blocked (needs human)
7. **Timestamps:** UTC ISO 8601 format

## Key Principles

- **Roles over genericism** — Each agent has a SOUL.md defining exactly who they are
- **Files over mental notes** — Only files persist between sessions
- **Staggered schedules** — Don't wake all agents at once
- **Shared context** — One source of truth for tasks and communication
- **Heartbeat, not always-on** — Balance responsiveness with cost
- **Human-in-the-loop** — Critical actions require approval
- **Guardrails over freedom** — Define what agents can and cannot do
- **Audit everything** — Every action logged to activity feed
