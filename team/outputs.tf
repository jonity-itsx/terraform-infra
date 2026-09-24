output "jumphost_external_ip" {
  description = "External IP of the jumphost instance"
  value       = google_compute_instance.jumphost.network_interface[0].access_config[0].nat_ip
}
output "oslogin_sink_writer_identity" {
  description = "Sinks writer identity, needs roles/pubsub.publisher on topic"
  value       = google_logging_project_sink.oslogin_audit.writer_identity
}