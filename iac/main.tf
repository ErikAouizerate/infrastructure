# Reference an existing SSH key by its name (must be registered in Hetzner Console).
# This avoids managing the public key inside Terraform.
data "hcloud_ssh_key" "default" {
  name = var.ssh_key_name
}

# The single application server: CPX32 (4 vCPU / 8 GB / 160 GB) at fsn1, Ubuntu 24.04.
resource "hcloud_server" "app" {
  name         = "app"
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [data.hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.app.id]

  # Cloud-init runs on first boot. It moves sshd to the non-standard port
  # BEFORE anything else, so the managed firewall's 3254 rule is usable
  # immediately and port 22 never has to be opened (destroy/reapply-safe).
  # NOTE: user_data is ForceNew - changing it recreates the server.
  # The drop-in only sets "Port" (NOT root/password): Ansible takes over the
  # rest of the sshd config and removes this drop-in afterwards.
  user_data = <<-EOT
    #cloud-config
    write_files:
      - path: /etc/ssh/sshd_config.d/99-bootstrap.conf
        content: |
          Port ${var.ssh_port}
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
    direction   = "in"
    protocol    = "tcp"
    port        = tostring(var.ssh_port)
    source_ips  = var.ssh_allowed_ips
    description = "SSH admin access"
  }

  # HTTP(S) open to the world for now (needed once Dockploy serves test apps).
  # To be restricted to Cloudflare IP ranges at the Cloudflare step.
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP (to be restricted to Cloudflare)"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS (to be restricted to Cloudflare)"
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
