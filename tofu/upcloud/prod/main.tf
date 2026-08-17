module "cluster" {
  source = "../modules/cluster"

  prefix       = "devhub"
  zone         = "de-fra1"
  node_plan    = "4xCPU-8GB"
  node_count   = 3
  network_cidr = "10.100.0.0/24"

  # Data services — production-grade plans
  pg_plan         = "2x2xCPU-4GB-100GB"
  pg_version      = "16"
  valkey_plan     = "1x1xCPU-2GB"
  objstore_region = "europe-1"

  termination_protection = true

  # Kubernetes API exposure — set in terraform.tfvars
  control_plane_ip_filter = var.api_allowed_cidrs

  # CI node group (tainted workload=ci) so build jobs never land on platform nodes
  ci_node_count = 2
  ci_node_plan  = "4xCPU-8GB"

  tags = {
    Environment = "prod"
    ManagedBy   = "tofu"
  }
}
