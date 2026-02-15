# Example terraform.tfvars file
# Copy this file to terraform.tfvars and adjust values as needed

prefix          = "tshub"
cluster_name    = "main"
zone            = "no-svg1"
node_plan       = "DEV-1xCPU-2GB"
node_count      = 2
network_cidr    = "10.100.0.0/24"

# For production, consider:
# node_plan       = "4xCPU-8GB"
# node_count      = 3
# control_plane_plan = "4xCPU-8GB"

# Managed data services
pg_plan         = "1x1xCPU-2GB-25GB"
pg_version      = "16"
valkey_plan     = "1x1xCPU-2GB"
objstore_region = "europe-1"
