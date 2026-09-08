terraform {
  backend "gcs" {
    bucket = "team4-tfstate-fd20a3b0" # namn på bucket från bootstrap
    prefix = "terraform/state"
  }
}
