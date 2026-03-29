# Operational Risks and Mitigations

This document identifies and documents operational risks, inconsistencies, and their mitigations for the cluster-agent-swarm-skills repository.

## Documented Inconsistencies

### 1. SKILL.md Documentation Inconsistency

**Issue**: Individual skill `SKILL.md` files lack the comprehensive security and runtime documentation present in the main `SKILL.md`.

**Impact**: Users installing individual skills may miss critical security warnings and runtime requirements.

**Affected Files**:
- `skills/orchestrator/SKILL.md`
- `skills/cluster-ops/SKILL.md`
- `skills/gitops/SKILL.md`
- `skills/security/SKILL.md`
- `skills/observability/SKILL.md`
- `skills/artifacts/SKILL.md`
- `skills/developer-experience/SKILL.md`

**Mitigation**: See main `SKILL.md` for:
- Runtime Requirements (credentials, tools)
- Security Assessment (source verification, third-party script warnings)
- Session Setup (environment configuration)

### 2. JSON Output Format Inconsistency

**Issue**: Scripts use different JSON output formats and not all scripts sanitize output for prompt injection.

**Impact**:
- Inconsistent parsing by LLM agents
- Potential prompt injection from untrusted output
- Difficulties in automated processing

**Mitigated Scripts** (with sanitization):
- `skills/observability/scripts/log-search.sh`
- `skills/observability/scripts/alert-triage.sh`

**Scripts Requiring Audit** (no sanitization):
- All other script outputs should be audited before production use

**Sanitization Pattern**:
```bash
# Output with sanitization wrapper
SANITIZED_JSON=$(jq '{ ... }')
sanitize_json_output "$SANITIZED_JSON"
```

### 3. Script Output Variance

**Issue**: Some scripts output only to stdout, some to stderr, and some to both.

**Impact**: Inconsistent logging and difficulty capturing structured output.

**Pattern** (established convention):
- stderr: Human-readable progress and errors
- stdout: JSON structured output for agent processing

## Operational Risks

### RISK-001: Third-Party Script Execution

**Severity**: CRITICAL

**Description**: Scripts are downloaded and executed from GitHub via `npx skills add`. This is a supply chain risk.

**Mitigation**:
- Always pin to verified commit hash
- Use manual git clone for highest security
- See `SECURITY.md` for detailed supply chain guidance

### RISK-002: Indirect Prompt Injection

**Severity**: HIGH

**Description**: Log and alert data from untrusted sources could contain malicious content interpreted by LLM agents.

**Mitigation**:
- Output sanitization implemented in observability scripts
- 500-character field truncation limits
- `sanitize_json_output()` wrapper marks sanitized content

### RISK-002: Production Modification Without Technical Approval

**Severity**: HIGH

**Description**: Documentation claims human approval is required, but this is procedural, not technical.

**Mitigation**:
- Your platform MUST enforce approval gates
- Do not rely on agent self-restriction
- See `SECURITY.md` for details

### RISK-003: Credential Exposure

**Severity**: HIGH

**Description**: Scripts may handle sensitive credentials via environment variables.

**Mitigation**:
- Use principle of least privilege
- Provide only required credentials for specific use case
- Never provide production credentials until code is audited

### RISK-004: Destructive Operations

**Severity**: MEDIUM

**Description**: Some scripts can perform destructive operations (deletion, cleanup).

**Mitigation**:
- Review scripts with `-delete`, `-cleanup` in name
- Test in non-production first
- Maintain offline verified copies

### RISK-005: External Network Calls

**Severity**: MEDIUM

**Description**: Scripts may make external network calls to download tools or send telemetry.

**Mitigation**:
- Only allow downloads from trusted sources
- Verify checksums for binary downloads
- Review telemetry endpoints before use

### RISK-006: Session State Persistence

**Severity**: MEDIUM

**Description**: Agents maintain persistent state (`WORKING.md`, `LOGS.md`, `MEMORY.md`).

**Mitigation**:
- Limit repository write access if concerned
- Review persisted files regularly
- Session isolation for different environments

## Version Inconsistencies

### Metadata Version Field

All `SKILL.md` files report `version: 1.0.0` in metadata. This should be updated when changes are made to individual skills.

**Current Version**: 1.0.3 (based on SECURITY.md security updates)

## Checklist for Safe Operation

Before using this skill in production:

- [ ] Read and understand `SECURITY.md`
- [ ] Pin installation to verified commit hash
- [ ] Review all scripts you plan to use
- [ ] Configure only required credentials (least privilege)
- [ ] Test in non-production environment first
- [ ] Ensure your platform enforces approval gates
- [ ] Review `OPERATIONAL_RISKS.md` for current risks
- [ ] Set up proper RBAC restrictions for agents

## Incident Response

If an operational issue occurs:

1. **Immediate Actions**:
   - Stop any running agent operations
   - Review agent logs (`LOGS.md`)
   - Check cluster state for unintended changes

2. **Investigation**:
   - Review which scripts were executed
   - Check credential access patterns
   - Review git history for changes

3. **Recovery**:
   - Roll back to known good state
   - Rotate potentially exposed credentials
   - Document lessons learned

## Change Log

| Date | Risk/Mitigation Added | Version |
|------|----------------------|----------|
| 2026-03-29 | Initial operational risks documentation | 1.0.3 |
| 2026-03-29 | Prompt injection mitigations for observability | 1.0.2 |
