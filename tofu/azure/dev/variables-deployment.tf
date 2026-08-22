# ─── Deployment identity ──────────────────────────────────────────────
#
# `prefix` names every resource this environment creates, including two
# names that are globally unique across all of Azure: the storage account
# (the prefix minus dashes) and the Key Vault. Two deployments sharing a
# prefix collide — within one subscription, and across subscriptions for
# those global names — so pick one per deployment, e.g. "acme-dev".

variable "prefix" {
  description = "Deployment identifier — prefixes every resource name, the storage account and the Key Vault"
  type        = string
  default     = "devhub-dev"

  validation {
    condition = (
      length(var.prefix) >= 3 && length(var.prefix) <= 16 &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.prefix))
    )
    error_message = "prefix must be 3-16 lowercase letters, digits or dashes, starting with a letter and not ending in a dash — short enough that the truncated storage-account and Key Vault names derived from it stay distinct."
  }
}

variable "deployed_by" {
  description = "Identity of the operator who configured this deployment (written by setup-env.sh; used only in tags)"
  type        = string
  default     = "unknown"
}
