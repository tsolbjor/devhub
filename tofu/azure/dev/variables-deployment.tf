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

variable "domain" {
  description = "Public DNS domain for this environment — an Azure DNS zone for it must already exist (set by setup-env.sh)"
  type        = string
}

variable "dns_zone_resource_group" {
  description = "Resource group holding the Azure DNS zone (empty = this deployment's own resource group)"
  type        = string
  default     = ""
}

variable "ci_node_vm_size" {
  description = <<-EOT
    VM size for the tainted spot CI node pool. The binding constraint is the
    subscription's LOW-PRIORITY vCPU quota in the region (check with
    `az vm list-usage`): a default trial quota of 3 cannot ever allocate the
    4-vCPU default, and CI builds sit Pending forever — pick a 2-vCPU size.
  EOT
  type        = string
  default     = "Standard_D4s_v3"
}
