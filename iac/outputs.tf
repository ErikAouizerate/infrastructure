output "server_ipv4" {
  description = "Public IPv4 address of the app server"
  value       = hcloud_server.app.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the app server"
  value       = hcloud_server.app.ipv6_address
}

output "server_id" {
  description = "Hetzner server ID (used by the Ansible inventory)"
  value       = hcloud_server.app.id
}
