# AGENTS.md

## Communication

- Speak French with the user. Write code, docs, and commits in English.
- The user is intermediate level: add explanatory comments on relevant lines so they can follow what each file does.

## Workflow

- Brainstorm features (in French) before building. Record design decisions in `docs/superpowers/specs/` and implementation plans in `docs/superpowers/plans/`; commit docs alongside code.
- Keep `IMPROVEMENTS.md` (todo/improvements) and `MANUAL_EDITS.md` (manual changes the user made) up to date.
- Secrets only in `.env` (gitignored); template in `.env.example`.

## Quick reference

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

`user_data` in `hcloud_server` is `ForceNew` — any change recreates the server, so
the full provisioning loop (inventory IP + both playbooks) must be re-run.

### Ansible (`provisioning/`)

```bash
cd provisioning
ansible-playbook playbooks/admin.yml --syntax-check
ansible-playbook playbooks/dokploy.yml --syntax-check
ansible-playbook playbooks/admin.yml   # hardening, sshd, Tailscale, swap, hostname
ansible-playbook playbooks/dokploy.yml  # Docker CE + Dokploy PaaS
```

**Order matters**: `admin.yml` (OS hardening) must run before `dokploy.yml`
(Docker + Dokploy). Ansible lives in `.venv/` (managed by `uv sync`),
auto-loaded by direnv.

### After `terraform apply`

Update `provisioning/inventory/hosts.yml` with the new IP from
`terraform output -raw server_ipv4`. The IP is hardcoded — no dynamic inventory.

## Key architecture

- Single Hetzner CPX32, Ubuntu 24.04, fsn1, IPv4+IPv6. Full design: `docs/superpowers/specs/`.
- Hetzner managed firewall (`hcloud_firewall`): stateful, implicit deny inbound. SSH on port 3254 (admin IPs only); HTTP/S restricted to Cloudflare IPs.
- cloud-init `user_data` creates sudo user `admin` and moves sshd to port 3254 at first boot. **Port 22 is never opened.** Ansible runs as `admin` on 3254.
- Ansible **must run with zero warnings**: `ansible_python_interpreter` pinned in group_vars, `remote_tmp` pre-created by cloud-init, stale collections removed.
- **App deployment onto Dokploy** (once the server is up) is a Dokploy HTTP API flow, not Ansible — use the `deploy-dokploy-app` skill in `.agents/skills/` (GitLab repo → compose → env vars → deploy → Let's Encrypt domain).

## Layout

- `iac/` — Terraform: providers, variables, server + firewall, outputs
- `provisioning/` — Ansible: inventory, group vars, playbooks (`admin.yml`, `dokploy.yml`), roles
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — design docs and impl plans
- `.envrc` — direnv: loads `.env` + puts `.venv/bin` on PATH

## Gotchas

- **Local Terraform state**: `terraform destroy` is impossible if `iac/.terraform/` is lost. Remote backend is a planned improvement.
- **Inventory IP is hardcoded** in `provisioning/inventory/hosts.yml` — must be updated manually after `terraform apply`.
- **`host_key_checking = False`** in `provisioning/ansible.cfg` (new server IP changes host key).
- **Dokploy install**: the `dokploy` role uses `curl | sh`, not Ansible modules.
