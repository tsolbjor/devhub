# _setup/ — generated per-environment state

Everything in here except this README is machine-written and gitignored.
One directory per environment (`_setup/aws-dev/`, `_setup/azure-dev/`, ...),
created by the setup scripts and read back on every run:

| File | Written by | Contents |
|------|-----------|----------|
| `config.yaml` | `devhub setup` | your interview answers (domain, ACME email, GitOps repo URL) — layered over the committed sample in `k8s/overlays/<env>/config.yaml` |
| `preflight.ok` | `devhub preflight` | marker that the external prerequisites were confirmed |
| `tofu-outputs.env` | `devhub sync` | hosts, IDs, buckets — everything tofu knows |
| `secrets.env` | `devhub sync` | database/cache passwords and IdP secrets from tofu |
| `manual-secrets.env` | `devhub setup` / you | values no API can produce: mirror tokens, the GCP OAuth client |
| `kubeconfig` | `devhub sync` | cluster access for this environment |
| `vault-init-keys.json` | `devhub vault` | **Vault unseal/recovery keys — irreplaceable** |
| `logs/` | `devhub quickstart` | full output of every step it ran |

## Starting over

```bash
./devhub reset --env <env>
```

deletes the regenerable files (answers, outputs, kubeconfig, markers, logs) so
`quickstart` runs the interview again. It does **not** touch the cloud
resources, the remote tofu state, or `tofu/<cloud>/<tier>/backend.hcl` — the
pointer to that state — so a reset never orphans an existing environment.

Two files survive a plain reset:

- `vault-init-keys.json` — the only copy of Vault's unseal/recovery keys.
  Deleting it seals an existing Vault **forever**. `reset --force` deletes it
  anyway; do that only after the Vault it belongs to is gone.
- `manual-secrets.env` — tokens you created by hand; re-creatable, but tedious.

Deleting the whole directory by hand works too — the table above is what
you're deleting.
