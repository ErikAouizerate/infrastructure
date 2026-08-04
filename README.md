# Infrastructure

Terraform and Ansible infrastructure for provisioning servers on Hetzner Cloud.

Single server (Hetzner Cloud, `cpx32`, Ubuntu 24.04) protected by the managed
Hetzner firewall. See `docs/superpowers/specs/` for the design and rationale.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [uv](https://docs.astral.sh/uv/) (Python tooling + project venv)
- [direnv](https://direnv.net/) (auto-loads `.env` and the venv; hook must be in
  your shell: `eval "$(direnv hook zsh)"`)
- An SSH key registered in Hetzner Cloud

Ansible is not installed globally: it lives in the project venv.

```bash
uv sync        # creates .venv/ with Ansible (pyproject.toml)
direnv allow   # enable .envrc auto-loading (once)
```

## Configuration

Copy `.env.example` to `.env` and fill in the values. `.env` is loaded
automatically by direnv (via `.envrc`) whenever you `cd` into the repo. If you
don't use direnv, load it manually:

```bash
set -a && source .env && set +a
```

## Deploy / re-deploy from scratch

The server is created with a cloud-init `user_data` that, at first boot, creates
the sudo user `admin` (with your SSH key) and moves sshd to port `3254`
(disabling Ubuntu's socket activation, root and password login). This makes the
destroy -> apply -> provision loop lockout-safe: **port 22 is never opened and
there is no root bootstrap**.

```bash
# 1. Create the infrastructure (server + managed firewall)
cd iac
terraform init
terraform apply

# 2. Get the new public IP and put it in the inventory
terraform output -raw server_ipv4   # -> update provisioning/inventory/hosts.yml (ansible_host)

# 3. Provision the server (as admin, created by cloud-init)
cd ../provisioning
ansible-playbook playbooks/admin.yml   # idempotent, can be re-run
```

Access:

```bash
ssh -p 3254 admin@<server-ip>          # public SSH (firewall: admin IPs only)
ssh admin@<tailscale-ip>               # via Tailscale (100.x)
```

## Get server IPs

```bash
cd iac
terraform output
```

## Destroy

```bash
cd iac
terraform destroy
```

Note: local Terraform state lives in `iac/.terraform/`. Losing it makes
`terraform destroy` impossible (see `IMPROVEMENTS.md` for a remote backend).
