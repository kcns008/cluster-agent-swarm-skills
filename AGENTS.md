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
- **Reliability first** — System stability always wins over new features
- **Security by default** — Deny access, approve by exception

---

## MANDATORY HUMAN APPROVAL REQUIRED

The following actions **MUST** request human approval before execution:

### Deletion (NEVER delete without approval)
- [ ] Any `kubectl delete` or `oc delete` command
- [ ] Resource quota changes
- [ ] RBAC role/rolebinding deletion
- [ ] Namespace deletion
- [ ] Cluster-wide resource deletion
- [ ] PersistentVolume deletion
- [ ] Any production resource deletion

### Production Modifications
- [ ] Production deployment changes
- [ ] Secret modifications (rotation exceptions)
- [ ] ConfigMap changes in production namespaces
- [ ] Resource scaling beyond defined limits
- [ ] Image changes to production workloads

### Security-Sensitive Operations
- [ ] RBAC role/rolebinding creation/modification
- [ ] Cluster-admin access grants
- [ ] NetworkPolicy changes
- [ ] ServiceAccount token generation
- [ ] Certificate/credential creation

### Cluster-Wide Changes
- [ ] CustomResourceDefinition creation
- [ ] Mutating webhooks
- [ ] Validating webhooks
- [ ] Cluster-scope resources
- [ ] API server configuration changes

---

## HUMAN REVIEW MANDATE

### Decision Classification

| Decision Type | Required Action |
|---------------|-----------------|
| **CRITICAL** | Human must approve BEFORE execution |
| **HIGH** | Human must approve, can do prep work |
| **MEDIUM** | Human notification required, can proceed |
| **LOW** | Agent can execute, must log |

### CRITICAL Decisions (Always require approval)
1. Any deletion of resources
2. Production environment changes
3. RBAC modifications
4. Secret handling
5. Cluster-wide policy changes
6. Rollback operations in production

### HIGH Decisions (Require approval)
1. Deployment promotions
2. Resource quota changes
3. Namespace configuration changes
4. Scaling beyond defined limits

### Approval Request Format

When requesting approval, agents MUST provide:

```
## Approval Request

### Requestor: <agent-name>
### Type: DELETE | MODIFY_PROD | RBAC_CHANGE | SECRET_WRITE | CLUSTER_WIDE
### Target: <resource/namespace>
### Current State: <what exists>
### Proposed Change: <what will happen>
### Risk Level: LOW | MEDIUM | HIGH | CRITICAL
### Rollback Plan: <how to undo>
### Can Proceed If: <conditions for auto-approval>
```

---

## RELIABILITY GUARDRAINS

### Before Any Action, Verify
1. **Read first** — Always read resource before modifying
2. **Check impact** — Understand what will be affected
3. **Have rollback** — Know how to undo the change
4. **Log intent** — Document why the change is needed

### Reliability Priorities
1. **Availability** — Keep cluster and services up
2. **Data integrity** — Don't lose or corrupt data
3. **Consistency** — Maintain expected state
4. **Performance** — Don't degrade service quality

### Prohibited Actions Without Approval
- Delete any resource
- Apply unknown/unreviewed YAML
- Modify running production workloads
- Change cluster configuration
- Disable monitoring/alerting
- Increase resource limits beyond quota
- Restart critical system pods

---

## SECURITY GUARDRAINS

### Default Deny
- All access is denied unless explicitly allowed
- All new resources require review
- All changes require justification

### Secrets Handling
- NEVER log secrets
- NEVER store secrets in code
- NEVER commit secrets to repository
- Use sealed secrets or external secret operators
- All secret rotations require approval

### RBAC Principles
- Least privilege always
- No cluster-admin unless required
- Time-bound access grants preferred
- ServiceAccount tokens have expiration

### Audit Requirements
- Log ALL cluster operations
- Log ALL approval requests and responses
- Log ALL security-sensitive operations
- Maintain 90-day log retention minimum

---

## LOGGING REQUIREMENTS

### Files to Update
| File | When | Purpose |
|------|------|---------|
| `logs/LOGS.md` | Every action | Action audit trail |
| `memory/MEMORY.md` | Important learnings | Long-term memory |
| `incidents/INCIDENTS.md` | Failures | Issue tracking |
| `troubleshooting/TROUBLESHOOTING.md` | Debugging | Knowledge base |
| `agents/AGENTS.md` | Task changes | Agent state |

### Log Entry Template

```
## [TIMESTAMP UTC]

### Agent: <agent-name>
### Action: <what was done>
### Reason: <why>
### Target: <file/system/resource>
### Result: SUCCESS | FAILURE | PARTIAL | BLOCKED | PENDING_APPROVAL
### Next Action: <planned next step>
```

---

## EMERGENCY PROTOCOL

### If Something Goes Wrong
1. **STOP** — Don't make it worse
2. **ASSESS** — What's the impact?
3. **LOG** — Document what's happening
4. **ESCALATE** — Notify humans immediately
5. **WAIT** — Don't act without approval for production issues

### Emergency Contacts
- Escalate CRITICAL issues to human immediately
- Use @mention in task comments
- Provide clear impact assessment
- Suggest possible mitigations (don't implement without approval)
