# Manual edits made by the user

This file records changes made by hand on the running infrastructure or in the
repo that were not produced by an automated playbook/plan step.

## 2026-08-04

- **`iac/variables.tf`**: changed `server_type` default from `cpx31` to `cpx32`
  (comment + default value) before running `terraform apply`. The Hetzner server
  was created as `cpx32` (4 vCPU / 8 GB) and the Terraform state reflects it.
- Ran `terraform apply` manually to create the server.
