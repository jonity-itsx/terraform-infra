variable "project_id" {
  description = "The Google Cloud project ID"
  type        = string
}

variable "region" {
  description = "The Google Cloud region"
  type        = string
  default     = "europe-north2"
}

variable "jumphost_zone" {
  description = "Override zone for the jumphost instance. Defaults to the first zone in the region."
  type        = string
  default     = null
}

variable "primary_zone" {
  description = "Override zone for the primary instance. Defaults to the jumphost's zone."
  type        = string
  default     = null
}

variable "team_id" {
  description = "The team ID"
  type        = number
}

# Punkt 6 i workshopen: instruktören måste nå jumphosten på 22 från sitt nät,
# och Headscale på 8080 från reverse proxyn. Båda är krav så fort vi stramar
# åt något. De ligger som variabler för att vara lätta att hitta och ändra.
variable "instructor_cidr" {
  description = "The instructor's network. Required to keep SSH access to the jumphost (punkt 6)."
  type        = string
  default     = "10.0.0.0/24"
}

variable "instructor_proxy_cidr" {
  description = "The instructor's reverse proxy node. Required to keep Headscale reachable on 8080 (punkt 6)."
  type        = string
  default     = "10.0.0.2/32"
}

variable "extra_ssh_cidrs" {
  description = "Additional SSH sources beyond the instructor network. Defaults to the GCP IAP TCP forwarding range."
  type        = list(string)
  default     = ["35.235.240.0/20"]
}

variable "team_tailnet_cidrs" {
  description = "Tailnet IP addresses allowed to access Team 4 services"
  type        = list(string)

  default = [
    "100.64.0.2/32", # Jonas
    "100.64.0.3/32", # Jone
    "100.64.0.4/32", # Jon
    "100.64.0.6/32", # Wilma
    "100.64.0.7/32", # Liam
  ]
}

variable "os_admin_users" {
  type        = list(string)
  description = "List of Google identities (email addresses) granted OS Admin Login access to computing instance"
  default = [
    "dennis.heimbert@chasacademy.se",
    "jon.eskilsson@chasacademy.se",
    "jonas.beijbom@chasacademy.se",
    "wilma.kylvag@chasacademy.se",
    "liam.baltze@chasacademy.se",
    "jon.jonsson@chasacademy.se",
  ]
}
