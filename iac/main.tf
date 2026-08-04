# Reference an existing SSH key by its name (must be registered in Hetzner Console).
# This avoids managing the public key inside Terraform.
data "hcloud_ssh_key" "default" {
  name = var.ssh_key_name
}

# Cloudflare publishes its reverse-proxy IP ranges at this public endpoint.
# We use them to restrict HTTP/S access to Cloudflare only (L7 protection).
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

# The single application server: CPX32 (4 vCPU / 8 GB / 160 GB) at fsn1, Ubuntu 24.04.
resource "hcloud_server" "app" {
  name         = "app"
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [data.hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.app.id]

  # Cloud-init runs on first boot. It creates the sudo user "admin" and moves
  # sshd to the non-standard port (and disables root/password login) BEFORE
  # anything else, so the managed firewall's 3254 rule is usable immediately
  # and neither port 22 nor a root bootstrap is ever needed.
  # NOTE: user_data is ForceNew - changing it recreates the server.
  # The drop-in holds the whole sshd bootstrap; Ansible removes it once it
  # manages sshd itself via the main config.
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
      # Pre-create Ansible's remote tmp dirs with the right ownership, so
      # Ansible never has to create them itself under `become` (which emits a
      # "remote_tmp ... created with a mode of 0700" warning).
      - [install, -d, -m, "0700", -o, root, -g, root, /root/.ansible/tmp]
      - [install, -d, -m, "0700", -o, ${var.admin_user}, -g, ${var.admin_user}, /home/${var.admin_user}/.ansible/tmp]
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
    direction   = "in"
    protocol    = "tcp"
    port        = tostring(var.ssh_port)
    source_ips  = var.ssh_allowed_ips
    description = "SSH admin access"
  }

  # Only Cloudflare reverse-proxy IPs may reach the origin on ports 80/443.
  # The IP list is fetched from Cloudflare's public API at plan/apply time.
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = local.cloudflare_ips
    description = "HTTP (Cloudflare only)"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = local.cloudflare_ips
    description = "HTTPS (Cloudflare only)"
  }

  # ICMP for ping and, importantly, for IPv6 neighbor discovery: without this,
  # IPv6 address configuration breaks on the server.
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Ping and IPv6 neighbor discovery"
  }

  # No "out" rules: Hetzner's default then allows all outbound traffic.
}
