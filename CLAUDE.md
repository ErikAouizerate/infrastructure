# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Terraform + Ansible infrastructure for a single Hetzner Cloud server (`cpx32`,
Ubuntu 24.04, `fsn1`) that runs Dokploy (Docker Swarm PaaS). See
`docs/superpowers/specs/` for design rationale and `docs/superpowers/plans/`
for implementation plans (both organized by date-prefixed topic, e.g.
`iac-hetzner`, `ansible-admin`, `cloudflare-firewall`, `dokploy`).

## Setup

```bash
uv sync        # creates .venv/ with Ansible (pyproject.toml)
direnv allow   # enable .envrc auto-loading (.env + .venv/bin on PATH)
```

Copy `.env.example` to `.env` and fill in values (`HCLOUD_TOKEN`,
`TF_VAR_ssh_key_name`, `TF_VAR_admin_ssh_public_key`, `TF_VAR_ssh_allowed_ips`,
`TS_AUTHKEY`, `DOKPLOY_URL`, `DOKPLOY_API_KEY`). Secrets live only in `.env`
(gitignored) — never commit them; the template is `.env.example`.

## Commands

### Terraform (`iac/`)

```bash
cd iac                              # direnv loads .env + .venv/bin on PATH
terraform init                      # one-time (or after provider changes)
terraform fmt && terraform validate # before every plan
terraform plan                      # dry-run — no apply without user confirmation
terraform apply                     # creates/recreates server + firewall
terraform output                    # get server_ipv4, server_ipv6, server_id
terraform destroy                   # destroys everything
```

`user_data` on `hcloud_server` is `ForceNew` — any change recreates the server.

### Ansible (`provisioning/`)

```bash
cd provisioning
ansible-playbook playbooks/admin.yml --syntax-check
ansible-playbook playbooks/dokploy.yml --syntax-check
ansible-playbook playbooks/admin.yml    # hardening, sshd, Tailscale, swap, hostname
ansible-playbook playbooks/dokploy.yml  # Docker CE + Dokploy PaaS
```

Ansible lives in `.venv/` (managed by `uv sync`), auto-loaded by direnv.

### Full deploy from scratch

```bash
cd iac && terraform init && terraform apply
terraform output -raw server_ipv4   # -> update provisioning/inventory/hosts.yml (ansible_host)
cd ../provisioning
ansible-playbook playbooks/admin.yml
ansible-playbook playbooks/dokploy.yml
```

Access: `ssh -p 3254 admin@<server-ip>` (or the Tailscale 100.x address).

## Architecture

- **Single server**: Hetzner CPX32, Ubuntu 24.04, `fsn1`, IPv4+IPv6. No dynamic
  inventory — `provisioning/inventory/hosts.yml` has one hardcoded host.
- **Lockout-safe bootstrap**: cloud-init `user_data` (in `iac/main.tf`) creates
  the sudo user `admin` with the caller's SSH key and moves sshd to port
  `3254` (disabling socket activation, root login, and password auth) at
  first boot, before the firewall or Ansible ever run. **Port 22 is never
  opened and there is no root bootstrap step.** Ansible always connects as
  `admin` on `3254`.
- **Firewall**: Hetzner managed firewall (`hcloud_firewall`, stateful,
  implicit deny inbound), enforced before packets reach the OS — so a
  Docker-published port is still unreachable unless a rule allows it.
  - SSH 3254: admin CIDRs only (`TF_VAR_ssh_allowed_ips`).
  - HTTP/S (80/443): restricted to Cloudflare's published IP ranges, fetched
    live at plan/apply time via the `hashicorp/http` provider
    (`data.http.cloudflare_ips` in `iac/main.tf`).
  - ICMP open (needed for IPv6 neighbor discovery, not just ping).
  - No outbound rules defined — Hetzner's default allows all egress.
- **Provisioning is two playbooks in sequence**: `admin.yml` (OS hardening:
  unattended-upgrades, sshd config takes over from the cloud-init drop-in,
  Tailscale join, swapfile, base packages, hostname) then `dokploy.yml`
  (Docker CE + Dokploy via the `dokploy` role, which shells out to Dokploy's
  official `curl | sh` installer — not idempotent via Ansible modules, so the
  role checks `/etc/dokploy` and Swarm state first to stay safe on reruns).
- **Ansible must run with zero warnings**: `ansible_python_interpreter` is
  pinned in `provisioning/inventory/group_vars/all.yml`, `remote_tmp` dirs are
  pre-created by cloud-init with correct ownership, and the cloud-init sshd
  drop-in is removed once `admin.yml` takes over `/etc/ssh/sshd_config`
  directly (single source of truth).
- **App deployment onto Dokploy** (once the server is up) is handled through
  the Dokploy HTTP API, not Ansible — see the `deploy-dokploy-app` skill in
  `.agents/skills/` for the full wizard (GitLab repo → compose → env vars →
  deploy → domain with Let's Encrypt).

## Layout

- `iac/` — Terraform: providers, variables, server + firewall, outputs
- `provisioning/` — Ansible: inventory, group vars, playbooks (`admin.yml`,
  `dokploy.yml`), roles (`dokploy`)
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — design docs and
  implementation plans, one pair per feature, committed alongside the code
  that implements them
- `.envrc` — direnv: loads `.env` and puts `.venv/bin` on PATH
- `IMPROVEMENTS.md` — running todo/improvement list; `MANUAL_EDITS.md` —
  manual changes made outside the normal spec/plan workflow, to be reconciled
  back into specs

## Gotchas

- **Local Terraform state**: `iac/.terraform/` and the `.tfstate` files are
  local only — losing them makes `terraform destroy` impossible (remote
  backend is a planned improvement, see `IMPROVEMENTS.md`).
- **Inventory IP is hardcoded** in `provisioning/inventory/hosts.yml` — must
  be updated manually after every `terraform apply` that recreates the server.
- **`host_key_checking = False`** in `provisioning/ansible.cfg` (a new server
  IP always changes the host key, by design here).
- **Dokploy install is not idempotent Ansible** — it's `curl | sh`; the role
  guards reruns by checking `/etc/dokploy` and Docker Swarm state instead.

## Workflow conventions

- Brainstorm features before building; record design decisions in
  `docs/superpowers/specs/` and implementation plans in
  `docs/superpowers/plans/`, committed alongside the code.
- Keep `IMPROVEMENTS.md` (todo/improvements) and `MANUAL_EDITS.md` (manual
  changes the user made outside this workflow) up to date as items are
  resolved — each is meant to be pruned once its entries are processed into
  specs/plans or applied.
