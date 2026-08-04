# Ansible Admin Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the fresh Hetzner server reachable and hardened for administration: dedicated sudo user, sshd on port `3254` (root + password disabled), Tailscale, unattended-upgrades, swap, hostname.

**Architecture:** Ansible runs from the user's machine (control node) against the single server (`app`, IP `2.28.26.25`). The server's cloud-init `user_data` (in `iac/main.tf`) already moves sshd to port `3254` at first boot, so the playbook bootstraps as `root` over port `3254` — **port 22 is never opened**. Docker/Dockploy/Cloudflare are explicitly out of scope.

> **Note (updated after execution):** the original Task 0 of this plan opened a
> temporary firewall rule for port 22 to bootstrap. That approach was replaced
> by a cloud-init `user_data` bootstrap (`iac/main.tf`): the drop-in sets
> `Port 3254` and disables `ssh.socket`, and cloud-init creates the sudo user
> `admin` (with `admin_ssh_public_key`), so a fresh server is reachable as
> `admin` on 3254 immediately. The playbook then removes that drop-in once it
> manages sshd. This was validated by re-creating the server.

**Tech Stack:** Ansible (installed via `uv`), Ubuntu 24.04 target, Tailscale install script.

## Global Constraints

- Server `app`: `2.28.26.25` (IPv4), IPv6 `2a01:4f8:c014:625a::1`.
- Admin user: `admin`, sudo NOPASSWD, created by cloud-init (`user_data`) with
  the key from `TF_VAR_admin_ssh_public_key` (`.env`).
- sshd final state: `Port 3254`, `PermitRootLogin no`, `PasswordAuthentication no`
  (already set by cloud-init at boot; Ansible keeps them in the main config).
- No firewall rule for port `22` at all, and **no root bootstrap** — the
  playbook runs directly as `admin` on `3254`.
- Secrets only in `.env`: `TS_AUTHKEY` is consumed at runtime (never committed).
- Comments in English; user follows at intermediate level.

---

### Task 0: Local prerequisites (Ansible + cloud-init bootstrap on the server)

**Files:**
- Modify: `iac/main.tf` (add `user_data` to `hcloud_server`)

- [ ] **Step 1: Install Ansible via the project venv**

Run:
```bash
uv sync        # creates .venv/ with Ansible (see pyproject.toml)
.venv/bin/ansible --version
```
Expected: Ansible version output (e.g. `ansible [core 2.x]`). Note: the full `ansible` package bundles `ansible.posix`.

- [ ] **Step 2: Add `user_data` (cloud-init) to `iac/main.tf`**

Add to `hcloud_server.app`:

```hcl
  # Cloud-init runs on first boot. It moves sshd to the non-standard port
  # BEFORE anything else, so the managed firewall's 3254 rule is usable
  # immediately and port 22 never has to be opened (destroy/reapply-safe).
  # NOTE: user_data is ForceNew - changing it recreates the server.
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
```

`<<-EOT` strips leading whitespace, so the emitted `user_data` starts flush-left
with `#cloud-config`.

- [ ] **Step 3: Recreate the server with `user_data`**

Run (from repo root):
```bash
set -a && source .env && set +a
cd iac
terraform plan    # expects: server "must be replaced" (user_data is ForceNew)
terraform apply
```
Expected: server destroyed + recreated (new IP); `user_data` is delivered to
cloud-init. Wait a minute for first boot, then:

- [ ] **Step 4: Verify root SSH works on port 3254**

Run:
```bash
IP=$(cd iac && terraform output -raw server_ipv4)
ssh -p 3254 root@$IP 'echo OK && cat /etc/ssh/sshd_config.d/99-bootstrap.conf'
```
Expected: prints `OK`, then `Port 3254` (the cloud-init drop-in is in place, so
sshd listens on 3254 and port 22 was never needed).

- [ ] **Step 5: Commit**

```bash
cd ..
git add iac/main.tf
git commit -m "iac: cloud-init user_data bootstrap (sshd on 3254 at first boot)"
```

---

### Task 1: Provisioning skeleton

**Files:**
- Create: `provisioning/ansible.cfg`
- Create: `provisioning/inventory/hosts.yml`
- Create: `provisioning/group_vars/all.yml`

- [ ] **Step 1: Create `provisioning/ansible.cfg`**

```ini
[defaults]
inventory = inventory/hosts.yml
host_key_checking = False
pipelining = True
retry_files_enabled = False
```

- [ ] **Step 2: Create `provisioning/inventory/hosts.yml`**

```yaml
---
all:
  hosts:
    app:
      ansible_host: 2.28.26.25
      # The "admin" user is created by cloud-init (user_data in iac/main.tf),
      # so the playbook always runs as admin on port 3254 - no root phase.
      ansible_user: admin
      ansible_port: 3254
```

- [ ] **Step 3: Create `provisioning/group_vars/all.yml`**

```yaml
---
# SSH port sshd will listen on after provisioning (matches the firewall rule).
ssh_port: 3254

# Tailscale auth key, read from the local environment at runtime.
tailscale_authkey: "{{ lookup('env', 'TS_AUTHKEY') }}"

# Swapfile size in MiB.
swap_size_mb: 2048
```

- [ ] **Step 4: Sanity-check the admin key is set in `.env`**

Run:
```bash
grep TF_VAR_admin_ssh_public_key ../.env
```
Expected: a line with the `ssh-rsa` key (used by cloud-init to create `admin`).

- [ ] **Step 5: Commit**

```bash
cd ..
git add provisioning
git commit -m "provisioning: add ansible skeleton (cfg, inventory, group_vars)"
```

---

### Task 2: Admin playbook

**Files:**
- Create: `provisioning/playbooks/admin.yml`

- [ ] **Step 1: Create `provisioning/playbooks/admin.yml`**

```yaml
---
- name: Admin provisioning (bootstrap + hardening)
  hosts: app
  become: true
  tasks:
    # --- 1. System update ----------------------------------------------------
    - name: Update apt cache
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600
      tags: upgrade

    - name: Upgrade all packages
      ansible.builtin.apt:
        upgrade: dist
      tags: upgrade

    # --- 2. Automatic security updates --------------------------------------
    - name: Install unattended-upgrades
      ansible.builtin.apt:
        name: unattended-upgrades
        state: present

    - name: Enable periodic auto-upgrades
      ansible.builtin.copy:
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";
        dest: /etc/apt/apt.conf.d/20auto-upgrades
        owner: root
        group: root
        mode: "0644"

    # --- 3. Harden sshd (new SSH port, key-only) ----------------------------
    # Note: the sudo user "admin" was already created by cloud-init (server
    # user_data in iac/main.tf) - this playbook runs as "admin".
    - name: Set sshd port
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?Port\s'
        line: "Port {{ ssh_port }}"
      notify: Restart sshd

    - name: Disable root login over SSH
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PermitRootLogin\s'
        line: "PermitRootLogin no"
      notify: Restart sshd

    - name: Disable password authentication
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PasswordAuthentication\s'
        line: "PasswordAuthentication no"
      notify: Restart sshd

    # Ubuntu 24.04 runs sshd through socket activation: ssh.socket owns the
    # listening port (default 22) and ignores sshd_config's "Port". Disable it
    # so sshd binds the port defined in sshd_config (3254).
    - name: Disable ssh socket activation
      ansible.builtin.systemd:
        name: ssh.socket
        state: stopped
        enabled: false
      notify: Restart sshd

    # The cloud-init bootstrap drop-in (set at server creation) only set the
    # port. Once this playbook manages sshd via the main config, remove it so
    # there is a single source of truth.
    - name: Remove cloud-init bootstrap sshd drop-in
      ansible.builtin.file:
        path: /etc/ssh/sshd_config.d/99-bootstrap.conf
        state: absent
      notify: Restart sshd

    # --- 4. Tailscale --------------------------------------------------------
    - name: Download Tailscale installer
      ansible.builtin.get_url:
        url: https://tailscale.com/install.sh
        dest: /tmp/tailscale-install.sh
        mode: "0755"

    - name: Run Tailscale installer
      ansible.builtin.command: /tmp/tailscale-install.sh
      args:
        creates: /usr/bin/tailscale

    - name: Get Tailscale status
      ansible.builtin.command: tailscale status --json
      register: ts_status
      changed_when: false
      ignore_errors: true

    - name: Join the tailnet with the auth key
      ansible.builtin.command: >-
        tailscale up --authkey={{ tailscale_authkey }}
        --hostname={{ inventory_hostname }}
      when: ts_status.rc != 0 or '"Running"' not in ts_status.stdout
      no_log: true

    # --- 5. Swap + base packages --------------------------------------------
    - name: Create swapfile
      ansible.builtin.command: "fallocate -l {{ swap_size_mb }}M /swapfile"
      args:
        creates: /swapfile
      register: swapfile_created

    - name: Set swapfile permissions
      ansible.builtin.file:
        path: /swapfile
        owner: root
        group: root
        mode: "0600"

    - name: Format swapfile
      ansible.builtin.command: mkswap /swapfile
      when: swapfile_created.changed

    - name: Enable swap
      ansible.builtin.command: swapon /swapfile
      when: swapfile_created.changed

    - name: Add swap to fstab
      ansible.builtin.mount:
        path: none
        src: /swapfile
        fstype: swap
        opts: sw
        state: present

    - name: Install base packages
      ansible.builtin.apt:
        name:
          - curl
          - git
          - htop
          - jq
          - ca-certificates
        state: present

    # --- 6. Hostname ---------------------------------------------------------
    - name: Set hostname
      ansible.builtin.hostname:
        name: "{{ inventory_hostname }}"

  handlers:
    # Restart of sshd does NOT drop already-established connections, so the
    # current session (and this playbook) survives. New logins will need
    # port 3254 and the admin key.
    - name: Restart sshd
      ansible.builtin.systemd:
        name: ssh
        state: restarted
```

- [ ] **Step 2: Syntax check**

Run:
```bash
cd provisioning
ansible-playbook playbooks/admin.yml --syntax-check
```
Expected: `playbook: playbooks/admin.yml` with no error.

- [ ] **Step 3: Commit**

```bash
cd ..
git add provisioning/playbooks/admin.yml
git commit -m "provisioning: add admin hardening playbook"
```

---

### Task 3: Run the playbook and verify

- [ ] **Step 1: Run the playbook (as admin, created by cloud-init)**

Run:
```bash
set -a && source ../.env && set +a   # exports TS_AUTHKEY for the playbook
cd provisioning
ansible-playbook playbooks/admin.yml
```
Expected: all tasks OK (a few `changed`). The `upgrade: dist` step can take several minutes. `no_log` hides the auth key. The playbook connects as `admin` on 3254 — cloud-init already did the user + sshd bootstrap.

- [ ] **Step 2: Verify sshd listens on 3254**

Run (from the machine, as admin):
```bash
ssh -p 3254 admin@2.28.26.25 'sudo ss -tlnp | grep sshd'
```
Expected: `sshd ... LISTEN ... 0.0.0.0:3254` (and `:::3254`). Port 22 no longer listed. (Note: Ubuntu 24.04 uses socket activation — the playbook disables `ssh.socket` so sshd honors `Port 3254`.)

- [ ] **Step 3: Verify admin login over public SSH on 3254**

Run:
```bash
ssh -p 3254 admin@2.28.26.25 'echo OK && id && sudo whoami'
```
Expected: `OK`, `uid=1000(admin)... groups=...sudo`, and `root` (sudo works).

- [ ] **Step 4: Verify root login is refused**

Run:
```bash
ssh -p 3254 root@2.28.26.25 'echo should-not-print'
```
Expected: `Permission denied` (or `root@... Permission denied`).

- [ ] **Step 5: Verify Tailscale**

Run:
```bash
ssh -p 3254 admin@2.28.26.25 'tailscale status'
```
Expected: node `app` listed with a `100.x.y.z` IP. (Connecting over the tailnet from the user's machine is optional for now.)

- [ ] **Step 6: Verify swap + unattended-upgrades**

Run:
```bash
ssh -p 3254 admin@2.28.26.25 'free -h | grep -i swap; dpkg -l unattended-upgrades | tail -1; cat /etc/apt/apt.conf.d/20auto-upgrades'
```
Expected: swap of ~2 GiB, package listed, and the two `APT::Periodic` lines with value `"1"`.

- [ ] **Step 7: Commit** (only if the playbook file needed fixes during the run)

```bash
git add provisioning
git commit -m "provisioning: fix admin playbook after run"
```

---

### Task 4: Cleanup — switch inventory to admin/3254

**Files:**
- Modify: `provisioning/inventory/hosts.yml` (admin on 3254)

No firewall change is needed: the bootstrap used cloud-init (port 22 was never
opened).

- [ ] **Step 1: Update the inventory to final state**

```yaml
      ansible_user: admin
      ansible_port: 3254
```

- [ ] **Step 2: Confirm 3254 works and port 22 is never open**

Run:
```bash
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/2.28.26.25/22' && echo "22 OPEN" || echo "22 blocked/dropped"
ssh -p 3254 admin@2.28.26.25 'echo ADMIN-OK'
```
Expected: `22 blocked/dropped`, then `ADMIN-OK`.

- [ ] **Step 3: Re-run the playbook idempotency check**

Run (as admin over 3254 now):
```bash
set -a && source ../.env && set +a
cd provisioning
ansible-playbook playbooks/admin.yml
```
Expected: no failures; mostly `ok`, minimal `changed` (proves idempotency).

- [ ] **Step 4: Commit**

```bash
cd ..
git add provisioning/inventory/hosts.yml
git commit -m "provisioning: switch inventory to admin user on port 3254"
```

---

## Notes for the implementer

- **Keep the running SSH session open** during the playbook run: after the sshd restart, the current connection survives but a NEW connection as root would be refused.
- **If locked out anyway:** the Hetzner Console rescue system is the fallback (boot rescue, mount disk, fix `/etc/ssh/sshd_config`).
- If `ansible.posix` is missing (`authorized_key` fails): ensure the full `ansible` package was installed via `uv sync`, not `ansible-core`.
- The `upgrade: dist` step may reboot the server if the kernel is updated; the playbook connection can drop. Rerun the playbook afterwards — it is idempotent.
