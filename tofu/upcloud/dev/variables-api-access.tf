# Who may reach the Kubernetes API server.
#
# Deliberately has no default: leaving a control plane open to 0.0.0.0/0 should be
# a written-down decision, not an inherited default. Set it in a tfvars file:
#
#   api_allowed_cidrs = ["203.0.113.4/32"]   # office egress
variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API endpoint"
  type        = list(string)

  # UpCloud has no private control-plane endpoint: an empty filter locks everyone
  # out, including deploy.sh. On AWS/Azure/GCP an empty list selects a private
  # endpoint instead — see k8s/docs/CLOUD_CAPABILITIES.md.
  validation {
    condition     = length(var.api_allowed_cidrs) > 0
    error_message = "UpCloud requires at least one CIDR: there is no private-endpoint mode, so [] would make the cluster unreachable."
  }
}
