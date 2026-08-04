# Dokploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Ansible role to install Docker CE and Dokploy on the Hetzner server.

**Architecture:** A single Ansible role `dokploy` executed by a dedicated playbook `dokploy.yml`. The role runs the official Dokploy install script (which handles Docker CE + Docker Swarm + Dokploy itself), with an idempotence guard and pre-install checks.

**Tech Stack:** Ansible, Docker CE, Docker Swarm, Dokploy

## Global Constraints

- The role runs with `become: true` on host `app` (port 3254, user `admin`)
- Installation method: `curl -sSL https://dokploy.com/install.sh | sh`
- Idempotent: skip if `/etc/dokploy` already exists
- Dashboard accessible via Tailscale on port 3000 only (Hetzer firewall blocks it publicly)
- ADVERTISE_ADDR is auto-detected by the script
- Latest version of Dokploy (no pinning)

---

### Task 1: Create role defaults and playbook

**Files:**
- Create: `provisioning/roles/dokploy/defaults/main.yml`
- Create: `provisioning/playbooks/dokploy.yml`

**Interfaces:**
- Consumes: nothing from prior tasks
- Produces: `dokploy_install_script_url`, `dokploy_config_dir` vars; playbook `dokploy.yml` that calls the role

- [ ] **Step 1: Create defaults**

```yaml
# provisioning/roles/dokploy/defaults/main.yml
---
dokploy_install_script_url: https://dokploy.com/install.sh
dokploy_config_dir: /etc/dokploy
```

- [ ] **Step 2: Create playbook**

```yaml
# provisioning/playbooks/dokploy.yml
---
- name: Install Dokploy (Docker CE + Dokploy PaaS)
  hosts: app
  become: true
  roles:
    - role: dokploy
```

- [ ] **Step 3: Validate syntax**

Run: `ansible-playbook playbooks/dokploy.yml --syntax-check`

Expected: `playbook: playbooks/dokploy.yml`

- [ ] **Step 4: Commit**

```bash
git add provisioning/roles/dokploy/defaults/main.yml provisioning/playbooks/dokploy.yml
git commit -m "feat: add dokploy role skeleton and playbook"
```

---

### Task 2: Implement role tasks

**Files:**
- Create: `provisioning/roles/dokploy/tasks/main.yml`

**Interfaces:**
- Consumes: `dokploy_install_script_url`, `dokploy_config_dir` from task 1
- Produces: Docker CE installed, Docker Swarm initialized, Dokploy service running on port 3000

- [ ] **Step 1: Write tasks file**

```yaml
# provisioning/roles/dokploy/tasks/main.yml
---
- name: Ensure prerequisites are installed
  ansible.builtin.apt:
    name:
      - curl
      - ca-certificates
    state: present
  become: true

- name: Check if Dokploy is already installed
  ansible.builtin.stat:
    path: "{{ dokploy_config_dir }}"
  register: dokploy_config_stat

- name: Block install if already present
  when: dokploy_config_stat.stat.exists
  block:
    - name: Verify Dokploy service is running
      ansible.builtin.shell:
        cmd: docker info --format '{{ '{{' }}.Swarm.LocalNodeState{{ '}}' }}'
      register: swarm_state
      changed_when: false
      failed_when: swarm_state.stdout != "active"

    - name: Dokploy already installed
      ansible.builtin.debug:
        msg: "Dokploy is already installed and Swarm is active. Skipping."
      changed_when: false

- name: Ensure ports 80, 443, 3000 are free
  ansible.builtin.shell:
    cmd: >
      ss -tulnp |
      grep -E ':(80|443|3000) ' &&
      echo "PORT OCCUPIED" || echo "PORTS FREE"
  register: port_check
  changed_when: false
  failed_when: "'PORT OCCUPIED' in port_check.stdout"
  when: not dokploy_config_stat.stat.exists

- name: Install Dokploy via official script
  ansible.builtin.shell:
    cmd: curl -sSL {{ dokploy_install_script_url }} | sh
  args:
    creates: "{{ dokploy_config_dir }}"
  register: install_result
  when: not dokploy_config_stat.stat.exists

- name: Verify Docker Swarm is active after install
  ansible.builtin.shell:
    cmd: docker info --format '{{ '{{' }}.Swarm.LocalNodeState{{ '}}' }}'
  register: swarm_state_post
  changed_when: false
  failed_when: swarm_state_post.stdout != "active"
  when: install_result is changed
```

- [ ] **Step 2: Validate syntax**

Run: `ansible-playbook playbooks/dokploy.yml --syntax-check`

Expected: `playbook: playbooks/dokploy.yml`

- [ ] **Step 3: Commit**

```bash
git add provisioning/roles/dokploy/tasks/main.yml
git commit -m "feat: implement dokploy role tasks"
```
