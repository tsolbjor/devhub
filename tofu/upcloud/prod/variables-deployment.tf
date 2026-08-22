# ─── Deployment identity ──────────────────────────────────────────────
#
# `prefix` names every resource this environment creates and seeds the
# object-storage bucket names. Two deployments sharing a prefix collide,
# so pick one per deployment, e.g. "acme-prod".

variable "prefix" {
  description = "Deployment identifier — prefixes every resource name and object-storage bucket"
  type        = string
  default     = "devhub-prod"

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
  # UpCloud label values reject most punctuation; operator identities are
  # usually emails, so squash anything outside the safe set.
  deployed_by_label = substr(replace(lower(var.deployed_by), "/[^a-z0-9_.-]/", "_"), 0, 63)
}
