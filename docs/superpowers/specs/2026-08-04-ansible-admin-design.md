# Design — Ansible provisioning, administration phase

Date: 2026-08-04
Status: validated (brainstormed with the user)
Roadmap step: provisioning, part 1 of 2 (administration only; Docker/Dockploy later)

## Context

The single Hetzner server (CPX32, Ubuntu 24.04) is deployed via Terraform
(`iac/`). To keep the destroy -> apply -> provision loop lockout-safe, the
server is created with a cloud-init `user_data` that moves sshd to port `3254`
and disables Ubuntu's `ssh.socket` at first boot. The managed firewall only
opens port `3254`, so after apply the server is already reachable on `3254` as
`root` (key-only); port `22` is never opened. The browser console cannot log in
because the cloud image has no root password (key-only).

This plan hardens the server for administration. It explicitly excludes Docker,
Dockploy and Cloudflare (later steps).

## Decisions

| Topic | Decision | Rationale |
|---|---|---|
| Admin account | dedicated sudo user `admin` (passwordless sudo), root login disabled at the end | Production practice; still a single-server learning setup |
| Admin SSH key | the user's `~/.ssh/id_rsa.pub` (per user) | The key registered in Hetzner (`erik123.contact@protonmail.com`) is used for the root bootstrap |
| SSH port | sshd on `3254`; `PermitRootLogin no`, `PasswordAuthentication no` | Non-standard port; key-only; matches the firewall rule |
| Admin access | public SSH `3254` (firewall, admin IPs) **and** Tailscale | Redundancy: SSH public as fallback, Tailscale as secondary path |
| Bootstrap path | cloud-init `user_data` sets `Port 3254` (drop-in) + disables `ssh.socket` at first boot; Ansible bootstraps as `root` on `3254` | No firewall change needed; port 22 stays closed forever; validated by re-creating the server |
| Ansible install | `uv tool install ansible` (uv already present) | Clean, isolated install |
| Swap | 2 GB swapfile | 8 GB RAM will be tight later (Docker apps + DBs) |
| Security extras | `unattended-upgrades` enabled | Automatic security patches |
| Excluded | fail2ban (low value: key-only + IP allowlist + managed firewall), timezone stays UTC, Docker, Dockploy, Cloudflare | Scope of this plan |
| Tailscale | install + join tailnet with `TS_AUTHKEY` from `.env` | Admin access from the user's machine |

## Playbook flow (lockout-safe ordering)

1. apt update + upgrade (tag `upgrade`)
2. enable `unattended-upgrades`
3. create `admin` (sudo NOPASSWD) + copy `id_rsa.pub` to its `authorized_keys`
4. sshd: port `3254`, `PermitRootLogin no`, `PasswordAuthentication no`
   (restart via handler; established session survives the listener restart)
5. remove the cloud-init bootstrap drop-in (`/etc/ssh/sshd_config.d/99-bootstrap.conf`)
   once Ansible manages sshd via the main config
6. Tailscale install + join (`TS_AUTHKEY`)
7. swapfile 2 GB + base packages (`curl`, `git`, `htop`, `jq`, `ca-certificates`)
8. hostname `app`

Safety nets if locked out: the running SSH session (keep it open during the
run), and the Hetzner Console rescue system.

## Out of scope

- Docker / Dockploy / app deployment — next plan.
- Cloudflare (L7, domain `ebag.click`) — last step.
- fail2ban, timezone change, monitoring.

## Accepted trade-offs

- Passwordless sudo for `admin`: simpler for Ansible + learning; acceptable on a
  single-user server. Revisit if the server gains other human users.
- SSH public `3254` remains reachable from the user's home IPs: convenient
  fallback; Tailscale-only hardening is a possible later step.
- Database backups (pg_dump → Hetzner Object Storage) are recommended but
  deferred to the Docker/Dockploy plan, when DBs actually exist.
