# Cloud Run service for the Go API, with its own service account and
# read access to the secrets it mounts as env vars.

resource "google_service_account" "api" {
  project      = var.project_id
  account_id   = "${var.name}-api"
  display_name = "${var.name} API (Cloud Run)"
}

resource "google_secret_manager_secret_iam_member" "api" {
  for_each = var.secret_env

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_cloud_run_v2_service" "api" {
  project  = var.project_id
  name     = "${var.name}-api"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = var.labels

  template {
    service_account = google_service_account.api.email
    labels          = var.labels

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.api]
}

# Runs cmd/migrate from the same image, with the same identity and settings as the service. Deploys run
# it (make cloud-migrate) before rolling the service onto a new image; until they do, the new
# revision's /healthz reports the schema as behind and its startup probe keeps it from taking traffic.
# Migrations must stay compatible with the revision still serving while they run.
resource "google_cloud_run_v2_job" "migrate" {
  project  = var.project_id
  name     = "${var.name}-migrate"
  location = var.region
  labels   = var.labels

  template {
    labels     = var.labels
    task_count = 1

    template {
      service_account = google_service_account.api.email
      max_retries     = 0
      timeout         = "600s"

      containers {
        image   = var.image
        command = ["/migrate"]

        dynamic "env" {
          for_each = var.env
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.api]
}
