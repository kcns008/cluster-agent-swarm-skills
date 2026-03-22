# Security Policy

## Overview

This repository contains Kubernetes and OpenShift platform operations tools. Security is our top priority. This document outlines security practices, external dependencies, and verification requirements.

## Security Model

### Trust Boundaries

- **Trusted**: Code in this repository (after review)
- **Untrusted**: External binaries, container images, and remote resources
- **Requires Verification**: All external downloads MUST be verified before execution

### External Dependencies

This project requires the following external tools. Install them via your package manager:

| Tool | Purpose | Installation Method | Verification |
|------|---------|---------------------|--------------|
| kubectl | Kubernetes CLI | Package manager (apt/yum/brew) | Check signature |
| oc | OpenShift CLI | Package manager or official mirror | Check checksum |
| helm | Helm package manager | Package manager | Check signature |
| kustomize | Kustomize CLI | Package manager | Check signature |
| jq | JSON processor | Package manager | Check signature |
| git | Version control | Package manager | System package |
| curl | HTTP client | Package manager | System package |
| trivy | Container scanner | Package manager or GitHub releases | Verify checksum |
| grype | Container scanner | Package manager or GitHub releases | Verify checksum |
| syft | SBOM generator | Package manager or GitHub releases | Verify checksum |
| cosign | Image signing | Package manager or GitHub releases | Verify checksum |

### Prohibited Patterns

The following patterns are **PROHIBITED** in this codebase:

1. **curl-pipe-bash**: `curl ... | sh` or `curl ... | bash`
2. **Unverified downloads**: Downloading binaries without checksum verification
3. **Remote script execution**: Executing scripts directly from URLs
4. **main branch dependencies**: Pin to specific releases, not floating branches

### Allowed Patterns

1. **Package manager installation**:
   ```bash
   # macOS
   brew install kubectl helm jq trivy

   # Ubuntu/Debian
   sudo apt-get install kubectl helm jq

   # RHEL/CentOS/Fedora
   sudo yum install kubectl helm jq
   ```

2. **Verified binary downloads** (with checksum verification):
   ```bash
   # Download with checksum verification
   curl -LO https://github.com/org/tool/releases/download/vX.Y.Z/tool-linux-amd64
   curl -LO https://github.com/org/tool/releases/download/vX.Y.Z/tool-linux-amd64.sha256
   sha256sum -c tool-linux-amd64.sha256
   chmod +x tool-linux-amd64
   sudo mv tool-linux-amd64 /usr/local/bin/tool
   ```

## Verification Requirements

### For External Binaries

Before using any external binary:

1. **Pin to specific version** - Never use "latest" or floating tags
2. **Verify checksum** - Compare SHA256 checksums with official releases
3. **Verify signature** - Where available, verify GPG signatures
4. **Use package manager** - Prefer system package managers when available

### For Container Images

When scanning container images:

1. Use image digests (`sha256:`) instead of tags
2. Verify image signatures with Cosign where available
3. Scan images before deployment

### Checksum Verification Script

Use the provided verification helper:

```bash
# Verify a downloaded binary
bash shared/lib/verify-binary.sh <binary-path> <expected-sha256>

# Example
bash shared/lib/verify-binary.sh ./trivy-linux-amd64 \
  "a1b2c3d4e5f6..."
```

## Security Checklist for Contributors

Before submitting changes:

- [ ] No `curl ... | sh` patterns
- [ ] No unverified external downloads
- [ ] All external tools use package managers or verified checksums
- [ ] No hardcoded credentials or secrets
- [ ] Scripts use `set -e` for error handling
- [ ] No execution of untrusted input
- [ ] RBAC permissions follow least privilege

## Reporting Security Issues

If you discover a security vulnerability:

1. **DO NOT** open a public issue
2. Email security concerns to: [security@example.com]
3. Include: Description, impact, reproduction steps, suggested fix
4. Allow 48 hours for initial response

## Security Updates

This section tracks security-related updates:

| Date | Update | Version |
|------|--------|---------|
| 2026-03-22 | Removed qmd skill (external download risk) | 1.0.1 |
| 2026-03-22 | Added SECURITY.md | 1.0.1 |
| 2026-03-22 | Replaced curl-pipe-bash with package manager installs | 1.0.1 |

## External Tool References

### Official Installation Sources

- **kubectl**: https://kubernetes.io/docs/tasks/tools/
- **Helm**: https://helm.sh/docs/intro/install/
- **Trivy**: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
- **Grype**: https://github.com/anchore/grype#installation
- **Syft**: https://github.com/anchore/syft#installation
- **Cosign**: https://docs.sigstore.dev/cosign/installation/

### Package Manager Availability

Most tools are available via:
- Homebrew (macOS): `brew install <tool>`
- APT (Debian/Ubuntu): `sudo apt-get install <tool>`
- YUM/DNF (RHEL/Fedora): `sudo yum install <tool>` or `sudo dnf install <tool>`
- Alpine: `apk add <tool>`

## License

This security policy is part of the project under the MIT License.
