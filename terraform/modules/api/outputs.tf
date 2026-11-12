output "url" {
  value = google_cloud_run_v2_service.api.uri
}

output "service_account_email" {
  value = google_service_account.api.email
}

output "migrate_job_name" {
  value = google_cloud_run_v2_job.migrate.name
}
