module "cluster" {
  source = "../modules/cluster"

  prefix       = "devhub-dev"
  zone         = "no-svg1"
  node_plan    = "DEV-1xCPU-2GB"
  node_count   = 2
  network_cidr = "10.100.0.0/24"

  # Data services — smallest plans for dev
  pg_plan         = "1x1xCPU-2GB-25GB"
  pg_version      = "16"
  valkey_plan     = "1x1xCPU-2GB"
  objstore_region = "europe-1"

  termination_protection = false

  # Kubernetes API exposure — set in terraform.tfvars
  control_plane_ip_filter = var.api_allowed_cidrs

  # CI node group (tainted workload=ci) so build jobs never land on platform nodes
  ci_node_count = 1
  ci_node_plan  = "4xCPU-8GB"

  tags = {
    Environment = "dev"
    ManagedBy   = "tofu"
  }
}
