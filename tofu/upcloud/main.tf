# Router for the private network
resource "upcloud_router" "kubernetes" {
  name = "${var.prefix}-${var.cluster_name}-router"
}

# Gateway for internet connectivity
resource "upcloud_gateway" "kubernetes" {
  name     = "${var.prefix}-${var.cluster_name}-gateway"
  zone     = var.zone
  features = ["nat"]
  router {
    id = upcloud_router.kubernetes.id
  }
}

# Private network for the Kubernetes cluster
resource "upcloud_network" "kubernetes" {
  name   = "${var.prefix}-${var.cluster_name}-network"
  zone   = var.zone
  router = upcloud_router.kubernetes.id
  
  ip_network {
    address            = var.network_cidr
    dhcp               = true
    dhcp_default_route = true
    family             = "IPv4"
    gateway            = cidrhost(var.network_cidr, 1)
  }
  
  depends_on = [upcloud_gateway.kubernetes]
}

# Kubernetes cluster
resource "upcloud_kubernetes_cluster" "main" {
  name                = "${var.prefix}-${var.cluster_name}"
  zone                = var.zone
  network             = upcloud_network.kubernetes.id
  control_plane_ip_filter = ["0.0.0.0/0"] # Allow access from anywhere (adjust for production)

  # Private node groups (workers will be in private network)
  private_node_groups = true
}

# Node group for worker nodes
resource "upcloud_kubernetes_node_group" "workers" {
  cluster = upcloud_kubernetes_cluster.main.id
  name    = "${var.prefix}-${var.cluster_name}-workers"
  node_count   = var.node_count
  plan    = var.node_plan
  anti_affinity = true # Spread nodes across different hosts for high availability 
  labels = {
    prefix = var.prefix
    cluster = var.cluster_name
    role = "worker"
    env  = lookup(var.tags, "Environment", "dev")
  }
  
  # Enable auto-scaling (optional)
  # Set min and max to same value for fixed size
  # autoscaling = {
  #   min = var.node_count
  #   max = var.node_count + 2
  # }
}
