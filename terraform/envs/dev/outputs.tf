output "api_url" {
  value = module.api.url
}

output "documents_bucket" {
  value = google_storage_bucket.documents.name
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "migrate_job_name" {
  value = module.api.migrate_job_name
}
