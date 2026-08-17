# ─── Platform service storage and keys ────────────────────────────────
#
# Backing resources for platform components that must not keep state on a local
# PVC: Loki (log storage), Velero (cluster backups), Vault (KMS auto-unseal).

resource "google_project_service" "kms" {
  project            = var.project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

# ─── Loki object storage ──────────────────────────────────────────────

resource "google_storage_bucket" "loki" {
  project       = var.project_id
  name          = "${var.prefix}-loki"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = !var.deletion_protection

  uniform_bucket_level_access = true
  labels                      = var.labels

  lifecycle_rule {
    condition {
      age = var.log_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "loki" {
  project      = var.project_id
  account_id   = "${var.prefix}-loki"
  display_name = "Loki chunk storage (Workload Identity)"
}

resource "google_storage_bucket_iam_member" "loki" {
  bucket = google_storage_bucket.loki.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.loki.email}"
}

resource "google_service_account_iam_member" "loki_workload_identity" {
  service_account_id = google_service_account.loki.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[monitoring/loki]"
}

# ─── Velero backup storage ────────────────────────────────────────────

resource "google_storage_bucket" "velero" {
  project       = var.project_id
  name          = "${var.prefix}-velero"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = !var.deletion_protection

  uniform_bucket_level_access = true
  labels                      = var.labels

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "velero" {
  project      = var.project_id
  account_id   = "${var.prefix}-velero"
  display_name = "Velero cluster backups (Workload Identity)"
}

resource "google_storage_bucket_iam_member" "velero" {
  bucket = google_storage_bucket.velero.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.velero.email}"
}

# Velero snapshots persistent disks as well as copying objects.
resource "google_project_iam_member" "velero_disks" {
  project = var.project_id
  role    = "roles/compute.storageAdmin"
  member  = "serviceAccount:${google_service_account.velero.email}"
}

resource "google_service_account_iam_member" "velero_workload_identity" {
  service_account_id = google_service_account.velero.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[velero/velero]"
}

# ─── Vault auto-unseal (Cloud KMS) ────────────────────────────────────
#
# With auto-unseal Vault decrypts its own root key on start, so unseal shares
# never need to be stored in a Kubernetes secret.

resource "google_kms_key_ring" "vault" {
  project  = var.project_id
  name     = "${var.prefix}-vault"
  location = var.region

  depends_on = [google_project_service.kms]
}

resource "google_kms_crypto_key" "vault_unseal" {
  name     = "vault-unseal"
  key_ring = google_kms_key_ring.vault.id
  purpose  = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_service_account" "vault" {
  project      = var.project_id
  account_id   = "${var.prefix}-vault"
  display_name = "Vault auto-unseal (Workload Identity)"
}

resource "google_kms_crypto_key_iam_member" "vault_unseal" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.vault.email}"
}

resource "google_service_account_iam_member" "vault_workload_identity" {
  service_account_id = google_service_account.vault.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[vault/vault]"
}
