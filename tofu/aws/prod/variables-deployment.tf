# ─── Deployment identity ──────────────────────────────────────────────
#
# `prefix` names every resource this environment creates and seeds the
# globally-unique namespaces (S3 buckets, the Cognito hosted-UI domain).
# Two deployments sharing a prefix collide — within one account, and across
# accounts for the global namespaces — so pick one per deployment,
# e.g. "acme-prod".

variable "prefix" {
  description = "Deployment identifier — prefixes every resource name, S3 bucket and the Cognito domain"
  type        = string
  default     = "devhub-prod"

  validation {
    condition = (
      length(var.prefix) >= 3 && length(var.prefix) <= 16 &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.prefix))
    )
    error_message = "prefix must be 3-16 lowercase letters, digits or dashes, starting with a letter and not ending in a dash."
  }

  validation {
    condition     = !can(regex("aws|amazon|cognito", var.prefix))
    error_message = "prefix must not contain \"aws\", \"amazon\" or \"cognito\" — Cognito rejects hosted-UI domains containing them."
  }
}

variable "deployed_by" {
  description = "Identity of the operator who configured this deployment (written by setup-env.sh; used only in tags)"
  type        = string
  default     = "unknown"
}
