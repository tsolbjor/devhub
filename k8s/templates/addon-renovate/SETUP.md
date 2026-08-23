# Finish setting up Renovate

The add-on is deployed, but the bot cannot talk to Forgejo until its token
exists in Vault. Three steps, all reversible:

## 1. Create the bot's Forgejo token

Preferably as a dedicated account, so PRs are clearly the bot's:

- Sign in to Forgejo as an admin at `https://git.DOMAIN`
- Site administration → Identity & Access → create user `renovate-bot`
- Add `renovate-bot` to the `devhub` organisation with **write** access
  (Owners team works too, but write is enough)
- Signed in as `renovate-bot`: Settings → Applications → Generate new token,
  with read/write on **repository**, **issue**, **pull request** and read on
  **organization** / **user**

## 2. Put the token in Vault

```sh
vault kv put secret/apps/addon-renovate token=<the token>
```

(That is the platform Vault, KV v2 mounted at `secret/`. The workload
cluster's External Secrets policy covers `apps/*`, so nothing else to grant.)

## 3. Let it sync and run

The ExternalSecret refreshes hourly; force it and trigger a first run:

```sh
kubectl annotate externalsecret renovate-token -n devhub-addon-renovate \
  force-sync="$(date +%s)"
kubectl create job --from=cronjob/renovate renovate-first-run -n devhub-addon-renovate
```

Then watch the job logs. Renovate opens an onboarding PR in each discovered
repository; merging that PR turns the bot on for that repo.

## Optional

- `GITHUB_COM_TOKEN` env var on the CronJob avoids rate limits when fetching
  changelogs of github.com-hosted dependencies.
- Tune `autodiscoverFilter`, `prHourlyLimit` in `k8s/renovate-config.yaml` and
  the schedule in `k8s/renovate-cronjob.yaml` — edit this repository, ArgoCD
  reconciles it.
