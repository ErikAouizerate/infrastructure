# Design — Single-server IaC on Hetzner (Terraform)

Date: 2026-08-04
Status: validated (brainstormed with the user)
Roadmap step: IaC (after "tools", before "provisioning")

## Context

The repo (IaC + provisioning of Hetzner cloud servers with Terraform and Ansible)
was restarted from scratch. The original design had two servers (an L4 gateway
doing NAT and a private application server) — that design was dropped during
brainstorming. We now target a single server protected by Hetzner's managed
firewall.

## Decisions

| Topic | Decision | Rationale |
|---|---|---|
| Server count | 1 server | Managed firewall makes a dedicated gateway redundant |
| Hetzner plan | CPX31 (4 vCPU / 8 GB / 160 GB), location `fsn1` | RAM is the bottleneck for 6-10 Docker apps with DBs; budget freed by dropping the gateway |
| Image | Ubuntu 24.04 LTS (`ubuntu-24.04`) | Smoothest Docker/Dockploy support; avoids RHEL/SELinux friction |
| IP addressing | public IPv4 + IPv6 | Primary IPv4 is included free; avoids NAT64 complexity |
| L4 firewall | Hetzner managed firewall (`hcloud_firewall`) | Free, stateful, implicit deny inbound, enforced before packets reach the OS |
| SSH | port `3254`, allowed only from `var.ssh_allowed_ips` | Non-standard port; strict source allowlist |
| HTTP | ports `80`/`443` open to the world for now | Needed once Dockploy serves test apps; restricted to Cloudflare IPs at the last step |
| Private network | none | Single server; nothing to isolate |
| NAT / nftables | none | Handled by the managed firewall |
| Terraform state | local (`.terraform/`) | Fine for learning; remote backend (Hetzner Object Storage, S3-compatible) noted as a future improvement |
| Terraform layout | flat files in `iac/` | Small footprint; no modules yet |

## Architecture

```
Internet ──> Cloudflare (L7, last step) ──> [80/443] ─┐
                                                   ▼
                              SINGLE SERVER (Hetzner, fsn1)
                              CPX31 · Ubuntu 24.04 · IPv4 + IPv6
                              ├─ hcloud_firewall (managed L4)
                              │    ├─ allow TCP 3254 from ssh_allowed_ips
                              │    ├─ allow TCP 80,443 from anywhere (tighten to Cloudflare later)
                              │    └─ deny everything else inbound / allow all outbound
                              ├─ (Ansible, next step) sshd on 3254, Tailscale, Docker, Dockploy
                              └─ apps: Docker Compose stacks managed by Dockploy
```

Because the managed firewall drops traffic before it reaches the OS, Docker
ports published with `-p` are not reachable from the internet unless a firewall
rule allows them.

## Terraform structure (`iac/`)

```
iac/
├── providers.tf      # provider hcloud (~> 1.63), required_providers block
├── variables.tf      # ssh_key_name, ssh_allowed_ips, server_type, location, ssh_port
├── main.tf           # data hcloud_ssh_key, hcloud_server, hcloud_firewall (+ apply)
└── outputs.tf        # server IPv4, IPv6, ID
```

Files are kept flat and commented (user is intermediate, wants to follow along).

## Inputs

| Variable | Env / source | Default | Example |
|---|---|---|---|
| `ssh_key_name` | `TF_VAR_ssh_key_name` | — | name of the SSH key registered in Hetzner |
| `ssh_allowed_ips` | `TF_VAR_ssh_allowed_ips` | — | `["1.2.3.4/32"]` |
| `server_type` | — | `cpx31` | `cpx31` |
| `location` | — | `fsn1` | `fsn1` |
| `ssh_port` | — | `3254` | `3254` |

`.env` is loaded with `set -a && source .env && set +a` before running
`terraform plan` / `apply`.

## Out of scope for this step

- Ansible provisioning (sshd on 3254, Tailscale, Docker, Dockploy) — separate
  spec + plan.
- Cloudflare (L7, domain `ebag.click`) — deliberately the last step.
- Remote Terraform state backend — future improvement.

## Risks / accepted trade-offs

- **Origin IP exposure**: the server's public IP can be discovered and attacked
  directly (e.g., DDoS). Mitigated by the managed firewall and, later, by
  restricting HTTP to Cloudflare IPs. Acceptable for ~100 users.
- **Local Terraform state**: losing `.terraform/` makes `terraform destroy`
  impossible. Noted as a future improvement.
- **Single point of failure**: one server hosts everything. Acceptable for this
  scale; a dedicated storage server is the documented escape hatch if needed.
- **Plan name/pricing**: CPX31 name and price to be confirmed on hetzner.com
  before applying.
