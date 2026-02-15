module "cluster" {
  source = "../modules/cluster"

  prefix       = "tshub"
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

  control_plane_ip_filter = ["0.0.0.0/0"] # TODO: restrict to known CIDRs

  tags = {
    Environment = "prod"
    ManagedBy   = "tofu"
  }
}
