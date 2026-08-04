# Infrastructure

Terraform and Ansible infrastructure for provisioning servers on Hetzner Cloud.

Single server (Hetzner Cloud, `cpx32`, Ubuntu 24.04) protected by the managed
Hetzner firewall. See `docs/superpowers/specs/` for the design and rationale.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
  installed via uv: `uv tool install ansible`
- A `.env` file configured at the root (see below)
- An SSH key registered in Hetzner Cloud

## Configuration

Copy `.env.example` to `.env` and fill in the values. Load it before any
Terraform/Ansible run:

```bash
set -a && source .env && set +a
```

## Deploy / re-deploy from scratch

The server is created with a cloud-init `user_data` that moves sshd to port
`3254` at first boot (and disables Ubuntu's socket activation). This makes the
destroy -> apply -> provision loop lockout-safe: **port 22 is never needed**.

```bash
# 1. Create the infrastructure (server + managed firewall)
cd iac
terraform init
set -a && source ../.env && set +a
terraform apply

# 2. Get the new public IP and put it in the inventory
terraform output -raw server_ipv4   # -> update provisioning/inventory/hosts.yml (ansible_host)

# 3. Provision the server (bootstrap phase: root on port 3254)
#    Edit provisioning/inventory/hosts.yml -> ansible_user: root
cd ../provisioning
set -a && source ../.env && set +a
ansible-playbook playbooks/admin.yml

# 4. Switch the inventory back to the admin user, then optionally re-run
#    provisioning/inventory/hosts.yml -> ansible_user: admin
ansible-playbook playbooks/admin.yml   # idempotent
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
set -a && source .env && set +a
cd iac
terraform destroy
```

Note: local Terraform state lives in `iac/.terraform/`. Losing it makes
`terraform destroy` impossible (see `IMPROVEMENTS.md` for a remote backend).
