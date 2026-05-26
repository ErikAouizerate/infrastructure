# Infrastructure

Terraform and Ansible infrastructure for provisioning servers on Hetzner Cloud.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- A `.env` file configured at the root (see below)

## Configuration

Copy and fill the following variables in your `.env` file:

```bash
TF_VAR_hcloud_token=<your-hetzner-api-token>
TF_VAR_ssh_key_name=<name-of-your-ssh-key-in-hetzner>
```

## Deploy the gateway server

```bash
# Load environment variables
source .env

# Initialize Terraform
cd iac
terraform init

# Load .env
set -a && source .env && set +a

# Preview changes
terraform plan

# Apply
terraform apply
```

## Get server IPs

```bash
terraform output
```

## Destroy

```bash
terraform destroy
```
