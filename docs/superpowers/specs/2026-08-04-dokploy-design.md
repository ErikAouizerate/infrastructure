# Ajout d'un rôle Ansible pour Dokploy (Docker CE + Dokploy PaaS)

**Date :** 2026-08-04

## Contexte

Le playbook `admin.yml` provisionne le serveur unique (hardening sshd, unattended-upgrades,
Tailscale, swap, paquets de base, hostname). Il manque encore Dokploy pour gérer les
déploiements applicatifs via Docker Compose.

## Décisions de design

- **Rôle unique** `dokploy` combinant installation de Docker CE et Dokploy.
- **Installation Docker** confiée au script officiel Dokploy (`curl -sSL https://dokploy.com/install.sh | sh`) plutôt qu'à Ansible directement.
- **Dashboard** accessible uniquement via Tailscale sur le port 3000 — le firewall Hetzner ne l'ouvre pas publiquement.
- **ADVERTISE_ADDR** laissé en auto-détection par le script.
- **Version** latest (non figée).

## Structure de fichiers

```
provisioning/
├── roles/
│   └── dokploy/
│       ├── defaults/
│       │   └── main.yml          # Variables par défaut
│       └── tasks/
│           └── main.yml          # Tâches d'installation
└── playbooks/
    ├── admin.yml                 # Existant — hardening, Tailscale, packages
    └── dokploy.yml               # Nouveau — installe Dokploy via le rôle
```

## Séquence du rôle `dokploy`

1. **Prérequis** — `apt` s'assure que `curl` et `ca-certificates` sont installés
   (rend le rôle autonome vis-à-vis de `admin.yml`).
2. **Vérification des ports** — `shell: ss -tulnp` vérifie que 80, 443, 3000
   sont libres ; sinon le tâche échoue explicitement.
3. **Garde d'idempotence** — Si `/etc/dokploy` existe, tout le rôle est skip.
4. **Installation** — `shell: curl -sSL {{ dokploy_install_script_url }} | sh`
   avec `creates: /etc/dokploy` et `changed_when: false` après le `creates`.
5. **Vérification post-install** — `shell` vérifie que Docker Swarm est actif
   (`docker info --format '{{.Swarm.LocalNodeState}}'` doit retourner `active`)
   et que le service Dokploy tourne.

## Variables (`defaults/main.yml`)

```yaml
---
dokploy_install_script_url: https://dokploy.com/install.sh
dokploy_config_dir: /etc/dokploy
```

## Playbook `dokploy.yml`

```yaml
---
- name: Install Dokploy (Docker CE + Dokploy PaaS)
  hosts: app
  become: true
  roles:
    - role: dokploy
```

## Ordre d'exécution

1. `ansible-playbook playbooks/admin.yml` (hardening, Tailscale, swap, paquets de base)
2. `ansible-playbook playbooks/dokploy.yml` (Docker CE + Swarm + Dokploy)

Tailscale est opérationnel avant Dokploy, donc l'admin peut accéder au dashboard
sur `http://<tailscale-ip>:3000` immédiatement après.

## Sécurité

- Le firewall Hetzner bloque le port 3000 depuis l'extérieur.
- Tailscale créant une interface réseau distincte, le trafic vers 3000
  transite par le tailnet et n'est pas filtré par le firewall Hetzner.
- Seuls les appareils autorisés dans le tailnet peuvent accéder au dashboard.

## Considérations futures

- Figer une version de Dokploy via tag GitHub si nécessaire.
- Configurer un sous-domaine Traefik pour le dashboard Dokploy (via HTTPS).
- Restreindre les ports 80/443 aux IPs Cloudflare uniquement.
