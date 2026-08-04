# Single-server Hetzner IaC (Terraform) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision one Hetzner Cloud server (CPX32, Ubuntu 24.04) with an attached managed firewall, from Terraform code in `iac/`.

**Architecture:** Single server with public IPv4 + IPv6, no private network, no NAT. The Hetzner managed firewall (`hcloud_firewall`) is the only L4 protection: stateful, implicit deny inbound, enforced before packets reach the OS (so Docker-published ports stay invisible from the internet). Cloudflare (L7) is a later, separate step.

**Tech Stack:** Terraform >= 1.0, provider `hetznercloud/hcloud` `~> 1.63`, Hetzner Cloud API (token via `HCLOUD_TOKEN`).

## Global Constraints

- Provider version floor: `hetznercloud/hcloud` `~> 1.63`.
- Server: `server_type = "cpx32"`, `location = "fsn1"`, image `ubuntu-24.04`, IPv4 + IPv6 enabled.
- `user_data` (cloud-init) on the server: writes an sshd drop-in `Port 3254`
  and disables `ssh.socket` at first boot, so the firewall's 3254 rule is usable
  immediately and port 22 never has to be opened (lockout-safe reapply).
- Firewall inbound rules: allow TCP `3254` (SSH) only from `var.ssh_allowed_ips`; allow TCP `80` and `443` from anywhere; allow ICMP (needed for ping and for IPv6 neighbor discovery — blocking ICMPv6 breaks IPv6). No outbound rules (Hetzner default = allow all egress).
- SSH key referenced by name via `data "hcloud_ssh_key"` (key already registered in Hetzner Console, not created by Terraform).
- Secrets only in `.env` (git-ignored): `HCLOUD_TOKEN`, `TF_VAR_ssh_key_name`, `TF_VAR_ssh_allowed_ips`, `TS_AUTHKEY`. Load with `set -a && source .env && set +a` before `terraform plan`/`apply`.
- Code comments in English, explanatory (the user follows along at intermediate level).
- No modules; flat `iac/` layout.

---

### Task 1: Provider and variables scaffolding

**Files:**
- Create: `iac/providers.tf`
- Create: `iac/variables.tf`

**Interfaces:**
- Produces: variables `ssh_key_name` (string), `ssh_allowed_ips` (list of string), `server_type` (string, default `cpx32`), `location` (string, default `fsn1`), `ssh_port` (number, default `3254`), `admin_user` (string, default `admin`), `admin_ssh_public_key` (string, from `TF_VAR_admin_ssh_public_key`). Task 2 consumes these exact names.

- [ ] **Step 1: Create `iac/providers.tf`**

```terraform
terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.63"
    }
  }
}

provider "hcloud" {
  # HCLOUD_TOKEN is read from the environment (set in root .env).
  # No token is hardcoded here: the hcloud provider picks up HCLOUD_TOKEN natively.
}
```

- [ ] **Step 2: Create `iac/variables.tf`**

```terraform
# Name of the SSH key registered in Hetzner Cloud (set via TF_VAR_ssh_key_name in .env).
variable "ssh_key_name" {
  description = "Name of the SSH key registered in Hetzner Cloud"
  type        = string
}

# JSON list of admin CIDRs allowed to SSH to the server
# (set via TF_VAR_ssh_allowed_ips in .env, e.g. TF_VAR_ssh_allowed_ips='["1.2.3.4/32"]').
variable "ssh_allowed_ips" {
  description = "Admin CIDRs allowed to SSH (port 3254)"
  type        = list(string)
}

# Hetzner server type. Default is cpx32 (4 vCPU / 8 GB / 160 GB).
variable "server_type" {
  description = "Hetzner Cloud server type"
  type        = string
  default     = "cpx32"
}

# Hetzner location. Default is fsn1 (Falkenstein).
variable "location" {
  description = "Hetzner Cloud location"
  type        = string
  default     = "fsn1"
}

# Non-standard SSH port the server will listen on (Ansible configures sshd later).
variable "ssh_port" {
  description = "SSH port allowed through the firewall"
  type        = number
  default     = 3254
}

# Sudo user created by cloud-init at first boot (Ansible connects as this user).
variable "admin_user" {
  description = "Sudo user created by cloud-init (Ansible connects as this user)"
  type        = string
  default     = "admin"
}

# Public SSH key for the admin user, injected by cloud-init at first boot.
variable "admin_ssh_public_key" {
  description = "Public SSH key for the admin user (cloud-init user_data)"
  type        = string
}
```

- [ ] **Step 3: Init Terraform in `iac/`**

Run (from repo root, `.env` must exist with `HCLOUD_TOKEN`):

```bash
set -a && source .env && set +a
cd iac
terraform init
```

Expected: provider `hcloud` downloaded, "Terraform has been successfully initialized!".

- [ ] **Step 4: Validate**

Run: `terraform validate`

Expected: `Success! The configuration is valid.` (unused variables are allowed).

- [ ] **Step 5: Commit**

```bash
cd ..
git add iac/providers.tf iac/variables.tf
git commit -m "iac: add hcloud provider and Terraform input variables"
```

---

### Task 2: Server and managed firewall

**Files:**
- Create: `iac/main.tf`

**Interfaces:**
- Consumes: variables from Task 1 (`ssh_key_name`, `ssh_allowed_ips`, `server_type`, `location`, `ssh_port`).
- Produces: `hcloud_server.app.id`, `hcloud_server.app.ipv4_address`, `hcloud_server.app.ipv6_address` (consumed by Task 3 for outputs).

- [ ] **Step 1: Create `iac/main.tf`**

```terraform
# Reference an existing SSH key by its name (must be registered in Hetzner Console).
# This avoids managing the public key inside Terraform.
data "hcloud_ssh_key" "default" {
  name = var.ssh_key_name
}

# The single application server: CPX32 (4 vCPU / 8 GB / 160 GB) at fsn1, Ubuntu 24.04.
resource "hcloud_server" "app" {
  name        = "app"
  image       = "ubuntu-24.04"
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.app.id]

  # Cloud-init runs on first boot. It creates the sudo user "admin" and moves
  # sshd to the non-standard port (and disables root/password login) BEFORE
  # anything else, so the managed firewall's 3254 rule is usable immediately
  # and neither port 22 nor a root bootstrap is ever needed.
  # NOTE: user_data is ForceNew - changing it recreates the server.
  user_data = <<-EOT
    #cloud-config
    users:
      - default
      - name: ${var.admin_user}
        groups: [sudo]
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        shell: /bin/bash
        ssh_authorized_keys:
          - ${trimspace(var.admin_ssh_public_key)}
    write_files:
      - path: /etc/ssh/sshd_config.d/99-bootstrap.conf
        content: |
          Port ${var.ssh_port}
          PermitRootLogin no
          PasswordAuthentication no
        permissions: "0644"
    runcmd:
      - [systemctl, disable, --now, ssh.socket]
      - [systemctl, restart, ssh]
  EOT

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # Label used by the provisioning step (Ansible) to target this server.
  labels = {
    role = "app"
  }
}

# Managed L4 firewall: stateful, implicit deny on inbound traffic, enforced
# BEFORE packets reach the OS. So even if Docker publishes a port (-p), it is
# unreachable from the internet unless a rule below allows it.
resource "hcloud_firewall" "app" {
  name = "app-firewall"

  # SSH on the non-standard port, restricted to the admin CIDRs.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = tostring(var.ssh_port)
    source_ips = var.ssh_allowed_ips
    description = "SSH admin access"
  }

  # HTTP(S) open to the world for now (needed once Dockploy serves test apps).
  # To be restricted to Cloudflare IP ranges at the Cloudflare step.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
    description = "HTTP (to be restricted to Cloudflare)"
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
    description = "HTTPS (to be restricted to Cloudflare)"
  }

  # ICMP for ping and, importantly, for IPv6 neighbor discovery: without this,
  # IPv6 address configuration breaks on the server.
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
    description = "Ping and IPv6 neighbor discovery"
  }

  # No "out" rules: Hetzner's default then allows all outbound traffic.
}
```

- [ ] **Step 2: Format and validate**

Run (from `iac/`):

```bash
terraform fmt -check
terraform validate
```

Expected: fmt reports no changes (or run `terraform fmt` to fix), validate returns `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
cd ..
git add iac/main.tf
git commit -m "iac: add app server (cpx32, ubuntu-24.04) with managed firewall"
```

---

### Task 3: Outputs and full plan check

**Files:**
- Create: `iac/outputs.tf`

**Interfaces:**
- Consumes: `hcloud_server.app.*` attributes from Task 2.
- Produces: outputs `server_ipv4`, `server_ipv6`, `server_id` (used later by the Ansible inventory).

- [ ] **Step 1: Create `iac/outputs.tf`**

```terraform
output "server_ipv4" {
  description = "Public IPv4 address of the app server"
  value       = hcloud_server.app.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the app server"
  value       = hcloud_server.app.ipv6_address
}

output "server_id" {
  description = "Hetzner server ID (used by the Ansible inventory)"
  value       = hcloud_server.app.id
}
```

- [ ] **Step 2: Validate and dry-run plan**

Run (from `iac/`, `.env` loaded):

```bash
terraform fmt -check
terraform validate
terraform plan
```

Expected: validate passes; `terraform plan` connects to the Hetzner API (reads the SSH key data source) and shows "Plan: 2 to add" (server + firewall), no errors. This is the acceptance gate for the IaC step.

- [ ] **Step 3: Commit**

```bash
cd ..
git add iac/outputs.tf
git commit -m "iac: add server outputs (ipv4, ipv6, id)"
```

---

## Notes for the implementer

- **Do NOT run `terraform apply`** in this step: provisioning (Ansible: sshd on 3254, Tailscale, Docker, Dockploy) comes in the next plan, and applying creates a billable server. Stop after `terraform plan` passes. Confirm with the user before any apply.
- If `terraform plan` fails with a 403/unauthorized: `HCLOUD_TOKEN` is missing or wrong in `.env`.
- If the SSH key data source errors "not found": the key name in `.env` (`TF_VAR_ssh_key_name`) does not match a key registered in Hetzner Console.
- The firewall has no outbound rules on purpose (default = allow all egress).
