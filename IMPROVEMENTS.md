# Improvements to be made

Backlog of improvements, in rough priority order. Update as work proceeds.

## Infrastructure

- [ ] **Remote Terraform state backend**: move from local `.terraform/` to
      Hetzner Object Storage (S3-compatible backend). Losing the local state
      makes `terraform destroy` impossible.
- [ ] **Restrict firewall HTTP(S) to Cloudflare IP ranges** (step Cloudflare).
      Currently `80`/`443` are open to the world.
- [ ] **SSH admin path**: consider Tailscale-only access (drop the public
      `3254` rule) once comfortable.
- [ ] **Tailscale node name**: the server joined as `app-1` because an old
      offline node `app` still exists in the tailnet. Rename/clean up in the
      Tailscale admin console.

## Provisioning

- [ ] **Docker + Dockploy** (next plan) for per-project Compose stacks.
- [ ] **Database backups to Hetzner Object Storage** (pg_dump/mysqldump via
      cron/rclone) before any real DB runs on the server.
- [ ] Add `deprecation_warnings = False` to `ansible.cfg` if module warnings
      bother the output.

## General

- [ ] Decide with the user how (and when) to migrate DBs to a dedicated
      PostgreSQL server (dump/restore, app by app). Documented rationale in
      `docs/superpowers/specs/2026-08-04-ansible-admin-design.md`.
