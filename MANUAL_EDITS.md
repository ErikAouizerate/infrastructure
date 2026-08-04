# Manual edits made by the user

This file records changes made by hand on the running infrastructure or in the
repo that were not produced by an automated playbook/plan step.

## 2026-08-04

- **`iac/variables.tf`**: changed `server_type` default from `cpx31` to `cpx32`
  (comment + default value) before running `terraform apply`. The Hetzner server
  was created as `cpx32` (4 vCPU / 8 GB) and the Terraform state reflects it.
- Ran `terraform apply` manually to create the server.
- Added `TF_VAR_admin_ssh_public_key` to `.env` and `.env.example` (the public
  key for the cloud-init `admin` user). The `.env` value was later rewritten by
  the agent to the quoted form `TF_VAR_admin_ssh_public_key="$(cat ~/.ssh/id_rsa.pub)"`
  so zsh's `source .env` no longer chokes on the spaces in the key.
