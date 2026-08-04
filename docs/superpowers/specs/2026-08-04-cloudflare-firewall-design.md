# Restreindre les ports HTTP/HTTPS aux IPs Cloudflare via le firewall Hetzner

**Date :** 2026-08-04

## Contexte

Le firewall Hetzner (`hcloud_firewall`) autorise actuellement le trafic HTTP (80) et
HTTPS (443) depuis n'importe quelle source (`0.0.0.0/0`, `::/0`). L'objectif est de
restreindre ces ports aux plages d'IPs publiées par Cloudflare, de sorte que seul
Cloudflare puisse atteindre le serveur d'origine (L7 protection).

## Décisions de design

- **Méthode :** Data source `http` native Terraform pour fetch
  `https://api.cloudflare.com/client/v4/ips`, parsée avec `jsondecode()`.
- **Provider :** `hashicorp/http ~> 3.4` (ne nécessite aucune clé API — données publiques).
- **Résilience :** `try(..., [])` autour du parsing pour éviter un crash si l'API
  Cloudflare est injoignable — les règles firewall auront alors `source_ips = []`
  (refus de tout trafic HTTP/HTTPS) plutôt qu'un `plan` qui échoue.
- **Automatisation :** Repoussée à plus tard (cron / CI).
- **IPv4 + IPv6 :** Concaténés en une seule liste `local.cloudflare_ips`.

## Fichiers modifiés

| Fichier | Modification |
|---|---|
| `iac/providers.tf` | Ajout du provider `hashicorp/http` |
| `iac/main.tf` | Ajout `data.http.cloudflare_ips`, `locals.cloudflare_ips`, mise à jour des 2 règles firewall |

## Détail des changements

### `iac/providers.tf`

Ajout du provider `http` dans `required_providers` :

```hcl
http = {
  source  = "hashicorp/http"
  version = "~> 3.4"
}
```

### `iac/main.tf`

**Data source :**
```hcl
data "http" "cloudflare_ips" {
  url = "https://api.cloudflare.com/client/v4/ips"
  request_headers = {
    Accept = "application/json"
  }
}
```

**Local :**
```hcl
locals {
  cloudflare_ips = concat(
    try(jsondecode(data.http.cloudflare_ips.response_body).result.ipv4_cidrs, []),
    try(jsondecode(data.http.cloudflare_ips.response_body).result.ipv6_cidrs, []),
  )
}
```

**Règles firewall modifiées :**
- `source_ips = ["0.0.0.0/0", "::/0"]` → `source_ips = local.cloudflare_ips`
- `description` mis à jour de `"HTTP (to be restricted to Cloudflare)"` à
  `"HTTP (Cloudflare only)"` (idem pour HTTPS).

## Sécurité

- Après `terraform apply`, seules les IPs Cloudflare pourront atteindre le serveur
  sur les ports 80/443.
- Si l'API Cloudflare est indisponible au moment du `plan`, les règles auront
  `source_ips = []` (HTTP/HTTPS bloqués pour tout le monde) — safer-side failure.
- Les autres règles du firewall (SSH, ICMP) ne sont pas modifiées.

## Considérations futures

- Automatiser les mises à jour via cron ou GitHub Actions (hebdomadaire).
- Surveiller les changements d'IPs Cloudflare pour réagir rapidement.
