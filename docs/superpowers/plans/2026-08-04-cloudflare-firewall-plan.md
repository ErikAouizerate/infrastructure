# Cloudflare Firewall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restrict HTTP/HTTPS firewall rules to Cloudflare IP ranges using Terraform's built-in HTTP data source.

**Architecture:** Add `hashicorp/http` provider, fetch Cloudflare IPs via `data.http`, parse with `jsondecode()`, and replace `0.0.0.0/0` / `::/0` with the dynamic IP list in the `hcloud_firewall` rules for ports 80 and 443.

**Tech Stack:** Terraform, hashicorp/http provider, Hetzner Cloud hcloud provider

## Global Constraints

- Provider `hashicorp/http` version `~> 3.4`
- API URL: `https://api.cloudflare.com/client/v4/ips`
- JSON path: `result.ipv4_cidrs` and `result.ipv6_cidrs`
- IPv4 + IPv6 are concatenated into a single list
- `try(..., [])` guards against API unavailability
- All changes are in `iac/`

---

### Task 1: Add HTTP provider and reinit

**Files:**
- Modify: `iac/providers.tf`

**Interfaces:**
- Consumes: nothing
- Produces: `http` provider available for `data.http` in Task 2

- [ ] **Step 1: Add `http` provider block**

```hcl
# iac/providers.tf (add to required_providers block)
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
```

- [ ] **Step 2: Reinit to download the new provider**

Run: `terraform init`

Expected: `Terraform has been successfully initialized!` with the http provider downloaded.

- [ ] **Step 3: Commit**

```bash
git add iac/providers.tf
git commit -m "feat: add hashicorp/http provider for Cloudflare IP lookup"
```

---

### Task 2: Add data source, locals, and update firewall rules

**Files:**
- Modify: `iac/main.tf`

**Interfaces:**
- Consumes: `http` provider from Task 1
- Produces: firewall rules using `local.cloudflare_ips` for ports 80/443

- [ ] **Step 1: Add data.http and locals block**

Add after the `data "hcloud_ssh_key"` block (around line 6) :

```hcl
data "http" "cloudflare_ips" {
  url = "https://api.cloudflare.com/client/v4/ips"

  request_headers = {
    Accept = "application/json"
  }
}

locals {
  cloudflare_ips = concat(
    try(jsondecode(data.http.cloudflare_ips.response_body).result.ipv4_cidrs, []),
    try(jsondecode(data.http.cloudflare_ips.response_body).result.ipv6_cidrs, []),
  )
}
```

- [ ] **Step 2: Update HTTP firewall rule**

Replace the HTTP rule (keep description concise as Hetzner has a limit):

```hcl
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = local.cloudflare_ips
    description = "HTTP (Cloudflare only)"
  }
```

- [ ] **Step 3: Update HTTPS firewall rule**

```hcl
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = local.cloudflare_ips
    description = "HTTPS (Cloudflare only)"
  }
```

- [ ] **Step 4: Format Terraform files**

Run: `terraform fmt`

Expected: no output or reformatted files.

- [ ] **Step 5: Validate with terraform plan**

Run: `terraform plan`

Expected: the plan should show the http/https firewall rules changing from `["0.0.0.0/0", "::/0"]` to the Cloudflare IP list (around 30+ CIDRs).

- [ ] **Step 6: Commit**

```bash
git add iac/main.tf
git commit -m "feat: restrict HTTP/S firewall to Cloudflare IP ranges"
```
