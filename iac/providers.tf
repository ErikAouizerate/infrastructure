terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.63"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "hcloud" {
  # HCLOUD_TOKEN is read from the environment (set in root .env).
  # No token is hardcoded here: the hcloud provider picks up HCLOUD_TOKEN natively.
}
