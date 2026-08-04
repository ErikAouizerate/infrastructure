# Name of the SSH key registered in Hetzner Cloud (set via TF_VAR_ssh_key_name in .env).
variable "ssh_key_name" {
  description = "Name of the SSH key registered in Hetzner Cloud"
  type        = string
}

# JSON list of admin CIDRs allowed to SSH to the server
# (set via TF_VAR_ssh_allowed_ips in .env, e.g. TF_VAR_ssh_allowed_ips='["1.2.3.4/32"]').
variable "ssh_allowed_ips" {
  description = "Admin CIDRs allowed to SSH (port 3254)"
  type        = list(string)
}

# Hetzner server type. Default is cpx32 (4 vCPU / 8 GB / 160 GB).
variable "server_type" {
  description = "Hetzner Cloud server type"
  type        = string
  default     = "cpx32"
}

# Hetzner location. Default is fsn1 (Falkenstein).
variable "location" {
  description = "Hetzner Cloud location"
  type        = string
  default     = "fsn1"
}

# Non-standard SSH port the server will listen on (Ansible configures sshd later).
variable "ssh_port" {
  description = "SSH port allowed through the firewall"
  type        = number
  default     = 3254
}
