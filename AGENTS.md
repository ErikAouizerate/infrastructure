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

Two Hetzner servers:

- Gateway/firewall: L4 firewall open on the internet, SSH on non-standard port
  `3254`. Public IP; IPv6-only preferred (cheaper on Hetzner).
- Applications server: closed to the internet, reachable only from the gateway
  over a private network (`192.168.0.0/16`, subnet `192.168.1.0/24`; the original
  `10.0.0.0/16` was dropped to avoid colliding with Docker networks — Docker's
  default pool is `172.16.0.0/12` and Tailscale uses `100.64.0.0/10`). Runs
  Dockploy to manage per-project Docker Compose stacks; DBs will be kept in the
  app Compose files initially (migrate to a dedicated storage server later only
  if it becomes constraining).
- Tailscale on both servers for admin access from the user's machine.
- Cloudflare in front for L7 firewall with domain `ebag.click` — deliberately the
  LAST step (requires config changes on Cloudflare side).

Server plans (from the user's notes):
- gateway: CX23, 2 vCPU / 4 GB / 40 GB / 20 TB (~€6.59/mo)
- applications: CPX22, 2 vCPU / 4 GB / 80 GB / 20 TB (~€23.39/mo)

## Environment variables (root `.env`)

- `HCLOUD_TOKEN` — Hetzner Cloud API token (consumed natively by the `hcloud`
  provider).
- `TF_VAR_ssh_key_name` — name of the SSH key registered in Hetzner Cloud.
- `TF_VAR_ssh_allowed_ips` — JSON list of admin CIDRs allowed to SSH to the
  firewall, e.g. `TF_VAR_ssh_allowed_ips='["1.2.3.4/32"]'` (single-quote so the
  shell keeps the quotes).
- `TS_AUTHKEY` — Tailscale auth key used by both servers.

`.env` is loaded with `set -a && source .env && set +a` before running
`terraform plan` / `apply`. `.tfvars` are git-ignored.

## Layout

- `iac/` — Terraform (to be created). Original design: gateway = `cpx22`,
  AlmaLinux (`alma-10`) image, SSH key via `data "hcloud_ssh_key"`; app server
  has no public IP and is attached to the private subnet at creation time.
- `provisioning/` — Ansible (to be created).
- `specs/` and `docs/superpowers/` — feature specs and plans.

## Terraform commands

```bash
source .env
cd iac
terraform init
terraform plan
terraform apply
terraform output   # get server IPs
terraform destroy
```
