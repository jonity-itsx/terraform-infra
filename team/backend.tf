terraform {
  backend "gcs" {
    bucket = "CHANGE_ME" # namn på bucket från bootstrap
    prefix = "terraform/state"
  }
}
