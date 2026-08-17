# Who may reach the Kubernetes API server.
#
# Deliberately has no default: leaving a control plane open to 0.0.0.0/0 should be
# a written-down decision, not an inherited default. Set it in a tfvars file:
#
#   api_allowed_cidrs = ["203.0.113.4/32"]   # office egress
#   api_allowed_cidrs = []                   # no public endpoint at all
variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint; [] disables public access"
  type        = list(string)
}

variable "aad_admin_group_object_ids" {
  description = "Entra ID group object IDs granted cluster-admin via Azure RBAC ([] keeps the local admin account enabled)"
  type        = list(string)
  default     = []
}
