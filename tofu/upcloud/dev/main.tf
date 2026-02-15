module "cluster" {
  source = "../modules/cluster"

  prefix       = "tshub-dev"
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

  tags = {
    Environment = "dev"
    ManagedBy   = "tofu"
  }
}
