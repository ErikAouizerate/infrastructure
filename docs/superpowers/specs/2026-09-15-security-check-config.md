# Security audit (`sec`) — skip vendored paths and fix the Ansible block check

**Date:** 2026-09-15

## Context

Running the bundled security audit (`sec all`, GHCR `security-check` image) failed
with exit code 1. The image's default policy is `FAIL_ON_SCA=1` for SCA but
`FAIL_ON_IAC=0`:

- `gitleaks` (secrets): 0 findings
- `opengrep` (SAST): 0 findings
- `osv-scanner`: 0 findings
- `checkov` (IaC): 1 finding
- `trivy config` + `trivy fs` (IaC/SCA): 83 findings

Every Trivy finding pointed inside `.venv/lib/python3.14/site-packages/ansible_collections/`:
third-party lockfiles (`Pipfile.lock`, `poetry.lock`, `yarn.lock`, Dockerfiles)
shipped inside the vendored Ansible collections. `.venv/` is gitignored and not a
source of truth, so these are false positives, not project dependencies. They
were the only reason the blocking `FAIL_ON_SCA=1` policy failed.

The one genuine finding was a Checkov Ansible check:

- `CKV2_ANSIBLE_3` — "Ensure block is handling task errors properly" at
  `provisioning/roles/dokploy/tasks/main.yml:15`: an Ansible `block:` without a
  `rescue:`/`always:`.

## Design decisions

- **Skip vendored/generated paths in Trivy via `trivy.yaml`.** Trivy
  automatically loads `trivy.yaml` from the current working directory (the
  mounted target, `/workspace`), and `scan.skip-dirs` applies to both
  `trivy config` and `trivy fs`. The skip list mirrors the image's
  `/etc/security-check/checkov.yaml` so every scanner ignores the same junk.
- **Do not disable any check.** Paths are skipped, detection quality is kept.
- **Fix the real Checkov finding in the source** rather than skipping it: add a
  `rescue:` that fails with an explicit message when Dokploy is installed but
  Docker Swarm is not active. This is more useful than the previous opaque
  failure on the `Verify Dokploy service is running` task.

## Files changed

| File | Change |
|---|---|
| `trivy.yaml` | New. `scan.skip-dirs` for vendored/generated directories |
| `provisioning/roles/dokploy/tasks/main.yml` | Added `rescue:` to the existing-install block |

## `trivy.yaml`

```yaml
scan:
  skip-dirs:
    - .venv
    - venv
    - node_modules
    - site-packages
    - __pycache__
    - .mypy_cache
    - .pytest_cache
    - .ruff_cache
    - .tox
    - .cache
```

## `provisioning/roles/dokploy/tasks/main.yml`

Added to the block that guards an existing installation:

```yaml
  rescue:
    - name: Fail if the existing Dokploy install is unhealthy
      ansible.builtin.fail:
        msg: >-
          Dokploy is installed ({{ dokploy_config_dir }} exists) but Docker
          Swarm is not active. Investigate the existing installation before
          continuing.
```

## Verification

- `ansible-playbook playbooks/dokploy.yml --syntax-check` → OK
- Re-ran `sec all .` → **exit 0**, 0 finding for every scanner
  (gitleaks, opengrep, osv, trivy config, trivy fs, checkov).

## Future considerations

- Keep `trivy.yaml` in sync with the image's Checkov skip list if either changes.
- The Terraform scanner still warns about unresolved variables
  (`admin_ssh_public_key`, `ssh_allowed_ips`, `ssh_key_name`) because the audit
  runs without `.tfvars`; this is a warning, not a finding.
