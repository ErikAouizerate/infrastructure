---
name: deploy-dokploy-app
description: Use when the user wants to deploy a new application on Dokploy from a GitLab repository via Docker Compose. Triggers: "deploy [project] on dokploy", "new dokploy app", "dokploy deploy", or any request mentioning a new service deployment with Docker Compose and GitLab.
---

# deploy-dokploy-app

Interactive wizard that deploys a new application on Dokploy from a GitLab repository via Docker Compose. Collects missing information through `question`, orchestrates the Dokploy API, and triggers the deployment.

## Prerequisites

The following must be set in the environment (`.env` or loaded):

| Variable | Required | Purpose |
|---|---|---|
| `DOKPLOY_API_KEY` | Yes | Dokploy API key for authentication |
| `DOKPLOY_URL` | Yes | Dokploy server URL, e.g. `http://100.x.y.z:3000` |
| `GITLAB_TOKEN` | No | GitLab personal access token (needed to read `.env.example` from private repos) |

The Dokploy API base URL is `${DOKPLOY_URL}/api`. Every request uses header `x-api-key: ${DOKPLOY_API_KEY}`.

## Wizard

Proceed through these steps. Use `question` to ask the user for each missing piece. Defaults are in **bold**.

### Step 1 — GitLab provider

Fetch the list of connected GitLab providers:

```bash
curl -s -H "x-api-key: $DOKPLOY_API_KEY" "$DOKPLOY_URL/api/gitlab.gitlabProviders"
```

Response is an array of objects with `gitlabId`, `name`, `gitlabUrl`, and a nested `gitProvider` object with `gitProviderId`. Ask the user to pick one if multiple; otherwise use the single one.

Result: `gitlabId`, `gitProviderId` (from the nested `gitProvider` object), `gitlabOwner` (the GitLab user/group name from the provider).

### Step 2 — GitLab repository

Fetch the list of repositories:

```bash
curl -s -H "x-api-key: $DOKPLOY_API_KEY" \
  "$DOKPLOY_URL/api/gitlab.getGitlabRepositories?gitlabId=$GITLAB_ID"
```

Response is an array of objects with fields like `id` (GitLab project numeric ID), `name`, `pathWithNamespace`, `owner`, `defaultBranch`. Present the list to the user.

Result: `gitlabProjectId` (numeric), `gitlabRepository` (name), `gitlabOwner`, `projectName` (from `pathWithNamespace`).

### Step 3 — Branch

Fetch branches:

```bash
curl -s -H "x-api-key: $DOKPLOY_API_KEY" \
  "$DOKPLOY_URL/api/gitlab.getGitlabBranches?owner=$GITLAB_OWNER&repo=$GITLAB_REPO&gitlabId=$GITLAB_ID"
```

Default: **`main`**. Ask user to confirm or pick another.

Result: `branch`.

### Step 4 — Subdomain

Ask the user: "Sous-domaine souhaité ? (ex: `bike` → `https://bike.ebag.click`)"

Result: `subdomain`. The full domain is `https://${subdomain}.ebag.click`.

### Step 5 — Docker Compose path

Ask the user: "Chemin du fichier docker-compose dans le repo ?"

Default: **`docker-compose.yml`**. This is the path relative to the repo root (e.g. `infra/docker-compose.yml`).

Result: `composePath`.

### Step 6 — Environment variables

Try to read env template files from GitLab. Search multiple filenames in order:

```bash
for FILE in .env.example sample.env .env.sample .env.local; do
  RESP=$(curl -sL --fail -o /dev/null -w "%{http_code}" \
    "https://gitlab.com/$GITLAB_OWNER/$GITLAB_REPO/-/raw/$BRANCH/$FILE" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN")
  if [ "$RESP" = "200" ]; then
    echo "Found: $FILE"
    curl -sL "https://gitlab.com/$GITLAB_OWNER/$GITLAB_REPO/-/raw/$BRANCH/$FILE" \
      -H "PRIVATE-TOKEN: $GITLAB_TOKEN"
    break
  fi
done
```

If none of the standard filenames work (e.g. private repo without `GITLAB_TOKEN`), try listing the repo root via the GitLab API:

```bash
curl -s "https://gitlab.com/api/v4/projects/$GITLAB_OWNER%2F$GITLAB_REPO/repository/tree?ref=$BRANCH&per_page=100" \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" 2>/dev/null \
| python3 -c "import sys,json; [print(f['name']) for f in json.load(sys.stdin) if 'env' in f['name'] and 'example' in f['name'] or f['name'].startswith('.env')]" 2>/dev/null
```

This will show files like `.env.example`, `sample.env`, `.env.docker`, etc. Try each one.

If a file is found, parse each `KEY=VALUE` or `KEY=` line (skip comments/blank). Present each variable to the user with `question` and let them fill in the value. Mark variables without a default value (just `KEY=`) as requiring user input.

If nothing is found (all 404 or no token for private repo), ask the user: "Quelles variables d'environnement veux-tu définir ? (format: KEY=VALUE, une par ligne, laisser vide pour ignorer)". Parse the multi-line answer.

Save the environment variables via the Dokploy API:

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"composeId\": \"$COMPOSE_ID\", \"env\": \"$ENV_CONTENT\"}" \
  "$DOKPLOY_URL/api/compose.saveEnvironment"
```

`ENV_CONTENT` is all variables as a single string with newlines: `KEY1=VALUE1\nKEY2=VALUE2`.

## API flow

After the wizard collects all inputs, execute this sequence:

### 1. Project

Check if project already exists:

```bash
curl -s -H "x-api-key: $DOKPLOY_API_KEY" "$DOKPLOY_URL/api/project.all"
```

Look for a project with `name == $PROJECT_NAME` (where `PROJECT_NAME` = the GitLab repo name from `pathWithNamespace`). If found, reuse its `projectId`. If not:

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$PROJECT_NAME\"}" \
  "$DOKPLOY_URL/api/project.create"
```

Result: `projectId`.

### 2. Environment

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"production\", \"projectId\": \"$PROJECT_ID\"}" \
  "$DOKPLOY_URL/api/environment.create"
```

Result: `environmentId`.

### 3. Compose (create)

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"App\", \"environmentId\": \"$ENVIRONMENT_ID\", \"appName\": \"${SUBDOMAIN}-app\", \"composeType\": \"docker-compose\"}" \
  "$DOKPLOY_URL/api/compose.create"
```

Result: `composeId` (extract from response).

### 4. Compose (update with GitLab source)

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"composeId\": \"$COMPOSE_ID\",
    \"sourceType\": \"gitlab\",
    \"gitlabProjectId\": $GITLAB_PROJECT_ID,
    \"gitlabRepository\": \"$GITLAB_REPOSITORY\",
    \"gitlabOwner\": \"$GITLAB_OWNER\",
    \"gitlabBranch\": \"$BRANCH\",
    \"gitlabPathNamespace\": \"$GITLAB_OWNER\",
    \"gitlabId\": \"$GITLAB_ID\",
    \"gitProviderId\": \"$GIT_PROVIDER_ID\",
    \"composePath\": \"$COMPOSE_PATH\"
  }" \
  "$DOKPLOY_URL/api/compose.update"
```

### 5. Save environment variables

Already done in Step 6 of the wizard. If user skipped env vars, skip this step.

### 6. Deploy

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"composeId\": \"$COMPOSE_ID\"}" \
  "$DOKPLOY_URL/api/compose.deploy"
```

### 7. Domain (Let's Encrypt TLS)

After the first deployment succeeds, set up the domain with HTTPS. Ask the user:

- **serviceName** — the Docker Compose service name to route traffic to (e.g. `app`, `web`, `webapp`)
- **port** — the container port Traefik should forward to (e.g. `80`, `3000`, `8080`)

Optionally validate DNS first:

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"domain\": \"$SUBDOMAIN.ebag.click\"}" \
  "$DOKPLOY_URL/api/domain.validateDomain"
```

Create the domain with Let's Encrypt:

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"host\": \"${SUBDOMAIN}.ebag.click\",
    \"composeId\": \"$COMPOSE_ID\",
    \"serviceName\": \"$SERVICE_NAME\",
    \"port\": $PORT,
    \"certificateType\": \"letsencrypt\",
    \"https\": true
  }" \
  "$DOKPLOY_URL/api/domain.create"
```

Then trigger a redeploy so Traefik picks up the new domain configuration:

```bash
curl -s -X POST -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"composeId\": \"$COMPOSE_ID\"}" \
  "$DOKPLOY_URL/api/compose.deploy"
```

## Output

Print a summary:

```
✅ Provider GitLab: <name>
✅ Projet "<projectName>" créé/réutilisé
✅ Environnement "production" créé
✅ Service "App" créé
   Source: <owner>/<repo>#<branch> → <composePath>
✅ <N> variables d'env sauvegardées
✅ Déploiement déclenché
✅ Domain "<subdomain>.ebag.click" créé avec Let's Encrypt

🔗 https://<subdomain>.ebag.click
```

If any step fails, print the error from the API response and stop. The user can fix and retry.

## Response format

Assuming success, the API response for compose.deploy is `{}` (empty object). The deployment starts asynchronously. The user can monitor progress in the Dokploy dashboard at `${DOKPLOY_URL}`.

## Common errors

| Error | Likely cause |
|---|---|
| `401 UNAUTHORIZED` | `DOKPLOY_API_KEY` is missing, wrong, or expired |
| `403 FORBIDDEN` | API key doesn't have permission for this operation |
| `404 NOT_FOUND` | GitLab project ID or compose ID doesn't exist |
| `400 BAD_REQUEST` | Missing required field in the request body |
| `.env.example` 404 | Project has no `.env.example` or the GitLab URL is wrong. Skip and ask user manually. |
| `hostname mismatch` in compose deploy | The compose file references a domain not configured in Dokploy. User must configure the domain first. |
| `Gitlab Provider not found` in deployment log | Missing `gitlabId` or `gitProviderId` on the compose resource. Run `compose.update` with these fields set. |
| `Path namespace not defined` in deployment log | Missing `gitlabPathNamespace` on the compose resource. Set it to the GitLab owner/group (same as `gitlabOwner`). |
