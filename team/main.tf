terraform {
  # ~> 1.15 betyder >= 1.15.0, < 2.0.0. Rymmer CI:s 1.15.7 och
  # lokalt installerade 1.16.x. Inte ~> 1.15.0, som hade låst till 1.15.x.
  required_version = "~> 1.15"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  team_zone     = (var.team_id - 1) % 3
  jumphost_zone = coalesce(var.jumphost_zone, data.google_compute_zones.available.names[local.team_zone])
  primary_zone  = coalesce(var.primary_zone, local.jumphost_zone)
  subnet_cidr   = "10.0.${var.team_id}.0/24"

  # concat, inte en platt lista, så att instruktörsnätet och vårt eget subnät
  # alltid finns med. Punkt 6 kräver det första, routingen det andra, och med
  # en enda lista går båda att råka redigera bort.
  #
  # subnet_cidr behövs för att jumphosten (10.0.x.2) ska nå primary (10.0.x.3).
  # Tailscale SNAT:ar dessutom subnet-routad trafik till jumphostens adress,
  # så tailnet-klienter landar på samma källa och täcks av samma post.
  ssh_source_ranges = concat(
    [var.instructor_cidr, local.subnet_cidr],
    var.extra_ssh_cidrs,
  )
}

data "google_compute_zones" "available" {
  region = var.region
}

data "google_compute_network" "team_vpc" {
  name = "team${var.team_id}-vpc"
}

resource "google_compute_subnetwork" "team" {
  name          = "team${var.team_id}-subnet"
  ip_cidr_range = local.subnet_cidr
  region        = var.region
  network       = data.google_compute_network.team_vpc.id
}

resource "google_compute_address" "jumphost" {
  name   = "team${var.team_id}-jumphost-ip"
  region = var.region
}

resource "google_compute_route" "internet_via_jumphost" {
  name              = "team${var.team_id}-internet-via-jumphost"
  network           = data.google_compute_network.team_vpc.id
  dest_range        = "0.0.0.0/0"
  priority          = 800
  next_hop_instance = google_compute_instance.jumphost.self_link
  tags              = ["no-external-ip"]
}

resource "google_compute_route" "tailnet_via_jumphost" {
  name              = "team${var.team_id}-tailnet-via-jumphost"
  network           = data.google_compute_network.team_vpc.id
  dest_range        = "100.64.0.0/10"
  priority          = 800
  next_hop_instance = google_compute_instance.jumphost.self_link
  tags              = ["no-external-ip"]
}

resource "google_compute_resource_policy" "daily_schedule" {
  name   = "team${var.team_id}-daily-schedule"
  region = var.region

  instance_schedule_policy {
    time_zone = "Europe/Stockholm"
    vm_start_schedule {
      schedule = "0 8 * * *"
    }
    vm_stop_schedule {
      schedule = "0 0 * * *"
    }
  }
}

resource "google_compute_instance" "jumphost" {
  name         = "team${var.team_id}-jumphost"
  machine_type = "e2-micro"
  zone         = local.jumphost_zone

  allow_stopping_for_update = true
  can_ip_forward            = true

  tags = ["jumphost"]

  resource_policies = [google_compute_resource_policy.daily_schedule.id]

  boot_disk {
    initialize_params {
      image = "${var.project_id}/debian"
      size  = 20
    }
  }

  service_account {
    email  = "team${var.team_id}-jumphost@${var.project_id}.iam.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }

  network_interface {
    subnetwork = google_compute_subnetwork.team.id
    network_ip = cidrhost(local.subnet_cidr, 2)
    access_config {
      nat_ip = google_compute_address.jumphost.address
    }
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = <<-EOT
  #!/bin/bash
  set -e

  if ! swapon --show | grep -q "/swapfile"; then
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  echo 'vm.swappiness=20' > /etc/sysctl.d/01-swappiness.conf
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ip-forward.conf
  sysctl --system

  DEFAULT_IF=$(ip ro sh default | awk '/default/ {print $5}')
  iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -s "${local.subnet_cidr}" -j MASQUERADE
  EOT
  }
}

# SSH. Namnet behålls trots att regeln nu bara hanterar port 22 — ett byte
# hade bytt resursadress och GCP-namn, alltså destroy och recreate, med risk
# att tappa SSH mitt i en apply.
resource "google_compute_firewall" "allow_traffic" {
  name    = "team${var.team_id}-allow-traffic"
  network = data.google_compute_network.team_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = local.ssh_source_ranges
  target_tags   = ["jumphost", "primary"]
}

# Firewall rule to allow our 5 IP addresses to access servers hosted by primary on port 8000
# Subnet routing will have to be off for this to work as the jumphost is not included 
resource "google_compute_firewall" "allow_primary_http" {
  name    = "team4-allow-primary-http"
  network = data.google_compute_network.team_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  source_ranges = var.team_tailnet_cidrs

  target_tags = ["primary"]
}
# Ger "primary" tillgång till internet via jumphost.
resource "google_compute_firewall" "allow_internal_to_jumphost" {
  name    = "team${var.team_id}-allow-internal-to-jumphost"
  network = data.google_compute_network.team_vpc.name

  allow {
    protocol = "all"
  }

  source_ranges = ["10.0.4.0/24"]
  target_tags   = ["jumphost"]
}
# Headscale nås bara av instruktörens reverse proxy, inte av hela internet.
resource "google_compute_firewall" "allow_headscale_proxy" {
  name    = "team${var.team_id}-allow-headscale-proxy"
  network = data.google_compute_network.team_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = [var.instructor_proxy_cidr]
  target_tags   = ["jumphost"]
}

# Tilldela osAdminLogin till alla e-postadresser i variabeln
resource "google_compute_instance_iam_member" "jumphost_os_login" {
  for_each      = toset(var.os_admin_users)
  instance_name = google_compute_instance.jumphost.name
  zone          = google_compute_instance.jumphost.zone
  role          = "roles/compute.osAdminLogin"
  member        = "user:${each.value}"
}

resource "google_compute_instance_iam_member" "primary_os_login" {
  for_each      = toset(var.os_admin_users)
  instance_name = google_compute_instance.primary.name
  zone          = google_compute_instance.primary.zone
  role          = "roles/compute.osAdminLogin"
  member        = "user:${each.value}"
}

# OBS: IAP-tunnelåtkomst hanteras INTE här, trots att den hör hemma i koden.
# roles/iap.tunnelResourceAccessor kräver iap.tunnelInstances.setIamPolicy för
# att sättas, och CI-kontets roles/editor saknar den. Egen minimal roll gick
# inte heller — vi saknar iam.roles.create i itsx25-lab.
#
# Tills vidare ligger bindningen på projektnivå, satt för hand med gcloud, på
# samma sätt som ett annat team redan gjort. Det ger tunnelåtkomst till varje
# instans i projektet, vilket är bredare än vi vill ha det.
#
# TODO: flytta tillbaka hit när CI kan sätta IAP-IAM, eller ersätt med
# tailnet-åtkomst via Headscale-ACL:er enligt punkt 8.

resource "google_compute_instance" "primary" {
  name         = "team${var.team_id}-primary"
  machine_type = "e2-small"
  zone         = local.primary_zone

  allow_stopping_for_update = true

  tags = ["primary", "no-external-ip"]

  resource_policies = [google_compute_resource_policy.daily_schedule.id]

  boot_disk {
    initialize_params {
      image = "${var.project_id}/debian"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.team.id
    network_ip = cidrhost(local.subnet_cidr, 3)
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = <<-EOT
  #!/bin/bash
  set -e

  if ! swapon --show | grep -q "/swapfile"; then
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  echo 'vm.swappiness=20' > /etc/sysctl.d/01-swappiness.conf
  sysctl --system
  EOT
  }
}
