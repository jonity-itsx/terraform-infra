terraform {
  # ~> 1.15 betyder >= 1.15.0, < 2.0.0. Rymmer CI:s 1.15.7 och
  # lokalt installerade 1.16.x. Inte ~> 1.15.0, som hade låst till 1.15.x.
  required_version = "~> 1.15"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "gcs" {
    bucket = "team4-tfstate-fd20a3b0"
    prefix = "terraform/bootstrap-state"
  }
}

provider "google" {
  project = var.project_id
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "terraform_state" {
  name     = "team${var.team_id}-tfstate-${random_id.bucket_suffix.hex}"
  location = "EU"

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
resource "google_storage_bucket_iam_member" "read_bucket" {
  for_each = toset(var.team_members)

  bucket = google_storage_bucket.terraform_state.name
  role   = "roles/storage.objectViewer"
  member = "user:${each.value}"
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "team${var.team_id}-github-pool"
  display_name              = "GitHub Actions Pool"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "team${var.team_id}-github-provider"
  display_name                       = "GitHub Actions Provider"

  # attribute.ref gör att editor-kontot kan bindas till bara main nedan.
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_condition = "assertion.repository == '${var.github_repo}'"
}

# GitHub Actions authenticates via Workload Identity Federation.
# Long-lived service account keys are intentionally not created.
resource "google_service_account" "cicd" {
  account_id   = "team${var.team_id}-cicd"
  display_name = "CI/CD Pipeline Service Account"
}

resource "google_project_iam_member" "cicd_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# Editor-kontot får bara användas från main. Providern släpper redan bara
# in var.github_repo, så ref räcker här. Tidigare gällde bindningen hela repot,
# och då gav en workflow på vilken gren som helst, eller i en PR, editor över
# hela det delade projektet utan review.
resource "google_service_account_iam_member" "cicd_workload_identity" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.ref/refs/heads/main"
}

# Läskonto för terraform plan i PR:er och för GCP-auditlarmet. Får användas
# från alla grenar och PR:er i repot, eftersom det inte kan ändra något.
resource "google_service_account" "cicd_plan" {
  account_id   = "team${var.team_id}-cicd-plan"
  display_name = "CI/CD Plan (read-only)"
}

resource "google_project_iam_member" "cicd_plan_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.cicd_plan.email}"
}

# roles/viewer räcker inte för att läsa objekt i bucketen, och plan behöver
# läsa state. PR-planen kör -lock=false, så skrivrätt behövs inte.
resource "google_storage_bucket_iam_member" "cicd_plan_state" {
  bucket = google_storage_bucket.terraform_state.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.cicd_plan.email}"
}

resource "google_service_account_iam_member" "cicd_plan_workload_identity" {
  service_account_id = google_service_account.cicd_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

