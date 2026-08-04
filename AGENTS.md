# AGENTS.md

## Communication

- Communicate with the user in French. Write code, documentation, and tests in English.
- The user is at an intermediate level in this domain: proceed step by step and add
  explanatory comments on relevant lines so they can follow what each file does.

## Workflow

- Brainstorm features with the user (in French) before building. Record design
  decisions in `docs/superpowers/specs/` and implementation plans in
  `docs/superpowers/plans/`; update them whenever architecture or scope changes.
  Commit docs alongside the code they document.
- Keep `IMPROVEMENTS.md` (improvements to be made) and `MANUAL_EDITS.md` (manual
  edits made by the user) up to date as work proceeds.
- Never put secrets, API keys, or sensitive data in code or committed files; always
  put them in `.env` (root, git-ignored). Provide a template in `.env.example`.

## Project goal

IaC + provisioning of cloud servers with Terraform (Hetzner Cloud) and Ansible,
built step by step: tools, IaC, provisioning.

Repo state: the initial commit's `iac/` and `specs/` were intentionally removed;
work starts fresh, one step at a time (tools -> IaC -> provisioning).

## Target architecture (planned)

A single Hetzner server (decided during brainstorming — the original 2-server
gateway design was dropped):

- One server: Hetzner **CPX32** (4 vCPU / 8 GB / 160 GB), location `fsn1`,
  Ubuntu 24.04 LTS, public IPv4 + IPv6.
- L4 protection = Hetzner managed firewall (`hcloud_firewall`, free, stateful,
  implicit deny inbound). SSH on non-standard port `3254` allowed only from
  `var.ssh_allowed_ips`; ports 80/443 open (to be restricted to Cloudflare IPs
  at the last step). No nftables, no NAT, no private network (single server).
- Runs Dockploy to manage per-project Docker Compose stacks; DBs are kept in the
  app Compose files (migrate to a dedicated storage server later only if
  constraining).
- Tailscale on the server for admin access from the user's machine.
- Cloudflare in front for L7 firewall with domain `ebag.click` — deliberately the
  LAST step (requires config changes on Cloudflare side).

Because the managed firewall drops traffic before it reaches the OS, Docker
ports published with `-p` are NOT reachable from the internet unless a firewall
rule allows them.

### Bootstrap (destroy -> apply -> provision) is lockout-safe

The server's `user_data` (cloud-init) creates the sudo user `admin` (key-only)
and moves sshd to port `3254` at first boot, disabling Ubuntu's `ssh.socket`
and root/password login. So after a fresh `terraform apply`, SSH is already
reachable as `admin` on 3254 — **port 22 is never opened and there is no root
bootstrap**. Ansible runs directly as `admin`. Note: `user_data` is `ForceNew`
— changing it recreates the server. The playbook removes the cloud-init sshd
drop-in once it manages sshd itself.

## Environment variables (root `.env`)

- `HCLOUD_TOKEN` — Hetzner Cloud API token (consumed natively by the `hcloud`
  provider).
- `TF_VAR_ssh_key_name` — name of the SSH key registered in Hetzner Cloud.
- `TF_VAR_ssh_allowed_ips` — JSON list of admin CIDRs allowed to SSH to the
  firewall, e.g. `TF_VAR_ssh_allowed_ips='["1.2.3.4/32"]'` (single-quote so the
  shell keeps the quotes).
- `TF_VAR_admin_ssh_public_key` — public key of the `admin` user, injected by
  cloud-init. Set with `TF_VAR_admin_ssh_public_key="$(cat ~/.ssh/id_rsa.pub)"`
  (must be quoted: the key contains spaces).
- `TS_AUTHKEY` — Tailscale auth key used by the server.

`.env` is loaded automatically by direnv (`.envrc` at the repo root also puts
`.venv/bin` on PATH, so `ansible*` and `terraform` just work after `cd`). If
direnv is not available, load `.env` manually with
`set -a && source .env && set +a`. `.tfvars` are git-ignored.

## Layout

- `iac/` — Terraform. Single server `cpx32`, Ubuntu 24.04 (`ubuntu-24.04`
  image), SSH key via `data "hcloud_ssh_key"`, attached managed firewall
  (`hcloud_firewall`), cloud-init `user_data` for the sshd bootstrap, no
  private network.
- `provisioning/` — Ansible. Inventory `inventory/hosts.yml`, group vars in
  `inventory/group_vars/` (must sit next to the inventory), playbooks in
  `playbooks/`. Admin playbook: apt, unattended-upgrades, sshd on 3254,
  Tailscale, swap, hostname. The `admin` user is created by cloud-init (not by
  Ansible).
- `.envrc` — direnv: activates `.venv` and loads `.env` automatically.
- `pyproject.toml` + `uv.lock` — project tooling (Ansible), venv via `uv sync`.
- `specs/` and `docs/superpowers/` — feature specs and plans.

## Terraform commands

```bash
cd iac           # direnv loads .env automatically
terraform init
terraform plan
terraform apply
terraform output   # get server IPs
terraform destroy
```
