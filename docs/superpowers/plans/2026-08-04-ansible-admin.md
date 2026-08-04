# Ansible Admin Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the fresh Hetzner server reachable and hardened for administration: dedicated sudo user, sshd on port `3254` (root + password disabled), Tailscale, unattended-upgrades, swap, hostname.

**Architecture:** Ansible runs from the user's machine (control node) against the single server (`app`, IP `2.28.26.25`). The playbook bootstraps as `root` over the temporarily-opened port `22`, then hardens sshd. Docker/Dockploy/Cloudflare are explicitly out of scope.

**Tech Stack:** Ansible (installed via `uv`), Ubuntu 24.04 target, `ansible.posix` for `authorized_key`, Tailscale install script.

## Global Constraints

- Server `app`: `2.28.26.25` (IPv4), IPv6 `2a01:4f8:c014:625a::1`.
- Admin user: `admin`, sudo NOPASSWD, key = control node `~/.ssh/id_rsa.pub`.
- sshd final state: `Port 3254`, `PermitRootLogin no`, `PasswordAuthentication no`.
- Firewall rule for port `22` is temporary (bootstrap only) — must be removed after the playbook.
- Secrets only in `.env`: `TS_AUTHKEY` is consumed at runtime (never committed).
- Comments in English; user follows at intermediate level.

---

### Task 0: Local prerequisites (Ansible + temporary port 22)

**Files:**
- Modify: `iac/main.tf` (add one firewall rule)

- [ ] **Step 1: Install Ansible via uv**

Run:
```bash
uv tool install ansible
ansible --version
```
Expected: Ansible version output (e.g. `ansible [core 2.x]`). Note: the full `ansible` package bundles `ansible.posix` (needed for `authorized_key`).

- [ ] **Step 2: Add temporary port-22 rule to `iac/main.tf`**

Insert after the SSH 3254 rule:

```hcl
  # TEMPORARY bootstrap rule: allows SSH on 22 while sshd is still on the
  # default port. Remove once Ansible has moved sshd to 3254.
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_allowed_ips
    description = "Bootstrap SSH on 22 (remove after Ansible)"
  }
```

- [ ] **Step 3: Apply the firewall change**

Run (from repo root):
```bash
set -a && source .env && set +a
cd iac
terraform plan
terraform apply
```
Expected: only the firewall changes (no server recreation).

- [ ] **Step 4: Verify root SSH works**

Run:
```bash
ssh -p 22 root@2.28.26.25 'echo OK'
```
Expected: prints `OK` (authenticates with the registered key). If `Permission denied`, check `~/.ssh/id_rsa` is the registered key.

- [ ] **Step 5: Commit**

```bash
cd ..
git add iac/main.tf
git commit -m "iac: temp open port 22 for Ansible bootstrap"
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
      # Bootstrap phase: root on port 22.
      # After the playbook: switch to admin on port 3254 (cleanup task).
      ansible_user: root
      ansible_port: 22
```

- [ ] **Step 3: Create `provisioning/group_vars/all.yml`**

```yaml
---
# SSH port sshd will listen on after provisioning (matches the firewall rule).
ssh_port: 3254

# Dedicated sudo user created by the playbook.
admin_user: admin

# Public key copied into admin's authorized_keys (read on the control node).
admin_ssh_public_key: "{{ lookup('file', lookup('env', 'HOME') ~ '/.ssh/id_rsa.pub') }}"

# Tailscale auth key, read from the local environment at runtime.
tailscale_authkey: "{{ lookup('env', 'TS_AUTHKEY') }}"

# Swapfile size in MiB.
swap_size_mb: 2048
```

- [ ] **Step 4: Sanity-check the key file exists**

Run:
```bash
ls -la ~/.ssh/id_rsa.pub
```
Expected: file present.

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

    # --- 3. Dedicated sudo user ----------------------------------------------
    - name: Create admin user
      ansible.builtin.user:
        name: "{{ admin_user }}"
        groups: sudo
        append: true
        shell: /bin/bash
        create_home: true

    - name: Grant passwordless sudo to admin
      ansible.builtin.copy:
        content: "{{ admin_user }} ALL=(ALL) NOPASSWD:ALL\n"
        dest: "/etc/sudoers.d/{{ admin_user }}"
        owner: root
        group: root
        mode: "0440"
        validate: "visudo -cf %s"

    - name: Install admin SSH public key
      ansible.posix.authorized_key:
        user: "{{ admin_user }}"
        key: "{{ admin_ssh_public_key }}"
        state: present

    # --- 4. Harden sshd (new SSH port, key-only) ----------------------------
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

    # --- 5. Tailscale --------------------------------------------------------
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

    # --- 6. Swap + base packages --------------------------------------------
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

    # --- 7. Hostname ---------------------------------------------------------
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

- [ ] **Step 1: Run the playbook (bootstrap as root on port 22)**

Run:
```bash
set -a && source ../.env && set +a   # exports TS_AUTHKEY for the playbook
cd provisioning
ansible-playbook playbooks/admin.yml
```
Expected: all tasks OK (a few `changed`). The `upgrade: dist` step can take several minutes. `no_log` hides the auth key.

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

### Task 4: Cleanup — remove port 22, switch inventory to admin/3254

**Files:**
- Modify: `iac/main.tf` (remove the temp port-22 rule)
- Modify: `provisioning/inventory/hosts.yml` (admin on 3254)

- [ ] **Step 1: Remove the temp port-22 rule from `iac/main.tf`**

Delete the rule added in Task 0 Step 2.

- [ ] **Step 2: Update the inventory to final state**

```yaml
      ansible_user: admin
      ansible_port: 3254
```

- [ ] **Step 3: Apply the firewall change**

```bash
set -a && source .env && set +a
cd iac
terraform apply
```
Expected: firewall updated (port 22 rule removed), server untouched.

- [ ] **Step 4: Confirm port 22 is closed and 3254 works**

Run:
```bash
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/2.28.26.25/22' && echo "22 OPEN" || echo "22 blocked/dropped"
ssh -p 3254 admin@2.28.26.25 'echo ADMIN-OK'
```
Expected: `22 blocked/dropped`, then `ADMIN-OK`.

- [ ] **Step 5: Re-run the playbook idempotency check**

Run (as admin over 3254 now):
```bash
set -a && source ../.env && set +a
cd provisioning
ansible-playbook playbooks/admin.yml
```
Expected: no failures; mostly `ok`, minimal `changed` (proves idempotency).

- [ ] **Step 6: Commit**

```bash
cd ..
git add iac/main.tf provisioning/inventory/hosts.yml
git commit -m "iac+provisioning: move to admin user on port 3254, close bootstrap port 22"
```

---

## Notes for the implementer

- **Keep the running SSH session open** during the playbook run: after the sshd restart, the current connection survives but a NEW connection as root would be refused.
- **If locked out anyway:** the Hetzner Console rescue system is the fallback (boot rescue, mount disk, fix `/etc/ssh/sshd_config`).
- If `ansible.posix` is missing (`authorized_key` fails): ensure the full `ansible` package was installed (`uv tool install ansible`), not `ansible-core`.
- The `upgrade: dist` step may reboot the server if the kernel is updated; the playbook connection can drop. Rerun the playbook afterwards — it is idempotent.
