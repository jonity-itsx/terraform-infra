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

variable "ssh_users" {
  description = "List of SSH users and their public keys for instance access"
  type = list(object({
    username   = string
    public_key = string
  }))
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
