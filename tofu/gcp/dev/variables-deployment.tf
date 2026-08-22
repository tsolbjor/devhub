# ─── Deployment identity ──────────────────────────────────────────────
#
# `prefix` names every resource this environment creates and seeds the
# globally-unique GCS bucket names. Two deployments sharing a prefix
# collide — within one project, and across projects for the buckets — so
# pick one per deployment, e.g. "acme-dev".

variable "prefix" {
  description = "Deployment identifier — prefixes every resource name and GCS bucket"
  type        = string
  default     = "devhub-dev"

  validation {
    condition = (
      length(var.prefix) >= 3 && length(var.prefix) <= 16 &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.prefix))
    )
    error_message = "prefix must be 3-16 lowercase letters, digits or dashes, starting with a letter and not ending in a dash."
  }
}

variable "deployed_by" {
  description = "Identity of the operator who configured this deployment (written by setup-env.sh; used only in labels)"
  type        = string
  default     = "unknown"
}

locals {
  # GCP label values allow only lowercase letters, digits, "_" and "-";
  # operator identities are usually emails, so squash everything else.
  deployed_by_label = substr(replace(lower(var.deployed_by), "/[^a-z0-9_-]/", "_"), 0, 63)
}
