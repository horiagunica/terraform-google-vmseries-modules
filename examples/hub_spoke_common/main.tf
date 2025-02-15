# ----------------------------------------------------------------------------------------------------------------
# Setup providers, pull availability zones, and create name prefix.

data "google_client_config" "main" {
}

data "google_compute_zones" "main" {
  project = data.google_client_config.main.project
  region  = var.region
}

resource "random_string" "main" {
  length    = 5
  min_lower = 5
  special   = false
}

locals {
  prefix = var.prefix != null && var.prefix != "" ? "${var.prefix}-" : ""

  vmseries_vms = {
    vmseries01 = {
      zone = data.google_compute_zones.main.names[0]
    }
    vmseries02 = {
      zone = data.google_compute_zones.main.names[1]
    }
  }
}


# ----------------------------------------------------------------------------------------------------------------
# Create mgmt, untrust, and trust networks

module "vpc_mgmt" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 4.0"
  project_id   = var.project_id
  network_name = "${local.prefix}mgmt-vpc"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name   = "${local.prefix}${var.region}-mgmt"
      subnet_ip     = var.cidr_mgmt
      subnet_region = var.region
    }
  ]

  firewall_rules = [
    {
      name        = "${local.prefix}vmseries-mgmt"
      direction   = "INGRESS"
      priority    = "100"
      description = "Allow ingress access to VM-Series management interface"
      ranges      = var.allowed_sources
      allow = [
        {
          protocol = "tcp"
          ports    = ["22", "443"]
        }
      ]
    }
  ]
}

module "vpc_untrust" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 4.0"
  project_id   = var.project_id
  network_name = "${local.prefix}untrust-vpc"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name   = "${local.prefix}${var.region}-untrust"
      subnet_ip     = var.cidr_untrust
      subnet_region = var.region
    }
  ]

  firewall_rules = [
    {
      name      = "${local.prefix}allow-all-untrust"
      direction = "INGRESS"
      priority  = "100"
      ranges    = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    }
  ]
}

module "vpc_trust" {
  source                                 = "terraform-google-modules/network/google"
  version                                = "~> 4.0"
  project_id                             = var.project_id
  network_name                           = "${local.prefix}trust-vpc"
  routing_mode                           = "GLOBAL"
  delete_default_internet_gateway_routes = true

  subnets = [
    {
      subnet_name   = "${local.prefix}${var.region}-trust"
      subnet_ip     = var.cidr_trust
      subnet_region = var.region
    }
  ]

  firewall_rules = [
    {
      name      = "${local.prefix}allow-all-trust"
      direction = "INGRESS"
      priority  = "100"
      ranges    = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    }
  ]
}


# ----------------------------------------------------------------------------------------------------------------
# Create VM-Series

# Create IAM service account for accessing bootstrap bucket
module "iam_service_account" {
  source = "../../modules/iam_service_account/"

  service_account_id = "${local.prefix}vmseries-sa"
}

# Create storage bucket to bootstrap VM-Series.
module "bootstrap" {
  source = "../../modules/bootstrap/"

  service_account = module.iam_service_account.email
  files = {
    "bootstrap_files/init-cfg.txt.sample"  = "config/init-cfg.txt"
    "bootstrap_files/bootstrap.xml.sample" = "config/bootstrap.xml"
  }
}

# Create 2 VM-Series firewalls
module "vmseries" {
  for_each = local.vmseries_vms
  source   = "../../modules/vmseries"

  name                  = "${local.prefix}${each.key}"
  zone                  = each.value.zone
  ssh_keys              = fileexists(var.public_key_path) ? "admin:${file(var.public_key_path)}" : ""
  vmseries_image        = var.fw_image_name
  create_instance_group = true

  metadata = {
    mgmt-interface-swap                  = "enable"
    vmseries-bootstrap-gce-storagebucket = module.bootstrap.bucket_name
    serial-port-enable                   = true
  }

  network_interfaces = [
    {
      subnetwork       = module.vpc_untrust.subnets_self_links[0]
      create_public_ip = true
    },
    {
      subnetwork       = module.vpc_mgmt.subnets_self_links[0]
      create_public_ip = true
    },
    {
      subnetwork = module.vpc_trust.subnets_self_links[0]
    }
  ]

  depends_on = [
    module.bootstrap
  ]
}


# ----------------------------------------------------------------------------------------------------------------
# Create internal and external load balancer to distribute traffic to VM-Series

# Due to intranet load balancer solution - DNAT for healthchecks traffic should be configured on firewall.
# Source: https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000PP9QCAW
module "lb_internal" {
  source = "../../modules/lb_internal/"

  name       = "${local.prefix}fw-ilb"
  backends   = { for k, v in module.vmseries : k => v.instance_group_self_link }
  ip_address = cidrhost(var.cidr_trust, 10)
  subnetwork = module.vpc_trust.subnets_self_links[0]
  network    = module.vpc_trust.network_id
  all_ports  = true
}

module "lb_external" {
  source = "../../modules/lb_external/"

  instances = [for k, v in module.vmseries : module.vmseries[k].self_link]
  name      = "${local.prefix}fw-extlb"
  rules = {
    "rule1" = { port_range = 80 },
    "rule2" = { port_range = 22 }
  }

  health_check_http_port         = 80
  health_check_http_request_path = "/"

}

module "vpc_spoke1" {
  source                                 = "terraform-google-modules/network/google"
  version                                = "~> 4.0"
  project_id                             = var.project_id
  network_name                           = "${local.prefix}spoke1-vpc"
  routing_mode                           = "GLOBAL"
  delete_default_internet_gateway_routes = true

  subnets = [
    {
      subnet_name   = "${local.prefix}${var.region}-spoke1"
      subnet_ip     = var.cidr_spoke1
      subnet_region = var.region
    }
  ]

  routes = [
    {
      name              = "${local.prefix}spoke1-to-ilbnh"
      description       = "Default route to VM-Series NGFW"
      destination_range = "0.0.0.0/0"
      next_hop_ilb      = cidrhost(var.cidr_trust, 10)
      #tags             = "egress-inet"
    }
  ]

  firewall_rules = [
    {
      name      = "${local.prefix}allow-all-spoke1"
      direction = "INGRESS"
      priority  = "100"
      ranges    = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    }
  ]
}

module "vpc_spoke2" {
  source                                 = "terraform-google-modules/network/google"
  version                                = "~> 4.0"
  project_id                             = var.project_id
  network_name                           = "${local.prefix}spoke2-vpc"
  routing_mode                           = "GLOBAL"
  delete_default_internet_gateway_routes = true

  subnets = [
    {
      subnet_name   = "${local.prefix}${var.region}-spoke2"
      subnet_ip     = var.cidr_spoke2
      subnet_region = var.region
    }
  ]

  routes = [
    {
      name              = "${local.prefix}spoke2-to-ilbnh"
      description       = "Default route to VM-Series NGFW"
      destination_range = "0.0.0.0/0"
      next_hop_ilb      = cidrhost(var.cidr_trust, 10)
      #next_hop_internet = "true"
      #tags             = "egress-inet"
    }
  ]

  firewall_rules = [
    {
      name      = "${local.prefix}allow-all-spoke2"
      direction = "INGRESS"
      priority  = "100"
      ranges    = ["0.0.0.0/0"]
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    }
  ]
}


# --------------------------------------------------------------------------------------------------------------------------
# Create VPC peering connections between trust network and the spoke networks
module "peering_trust_spoke1" {
  source = "../../modules/vpc-peering"

  local_network      = module.vpc_trust.network_id
  local_peering_name = "${local.prefix}trust-to-spoke1"
  peer_network       = module.vpc_spoke1.network_id
  peer_peering_name  = "${local.prefix}spoke1-to-trust"

  local_export_custom_routes                = true
  local_export_subnet_routes_with_public_ip = true

  peer_import_custom_routes                = true
  peer_export_subnet_routes_with_public_ip = true
}

module "peering_trust_spoke2" {
  source = "../../modules/vpc-peering"

  local_network      = module.vpc_trust.network_id
  local_peering_name = "${local.prefix}trust-to-spoke2"
  peer_network       = module.vpc_spoke2.network_id
  peer_peering_name  = "${local.prefix}spoke2-to-trust"

  local_export_custom_routes                = true
  local_export_subnet_routes_with_public_ip = true

  peer_import_custom_routes                = true
  peer_export_subnet_routes_with_public_ip = true
}

# --------------------------------------------------------------------------------------------------------------------------
# Create spoke1 compute instances with internal load balancer

resource "google_compute_instance" "spoke1_vm" {
  count                     = 2
  name                      = "${local.prefix}spoke1-vm${count.index + 1}"
  machine_type              = var.spoke_vm_type
  zone                      = data.google_compute_zones.main.names[0]
  can_ip_forward            = false
  allow_stopping_for_update = true

  metadata = {
    serial-port-enable = true
    ssh-keys           = fileexists(var.public_key_path) ? "${var.spoke_vm_user}:${file(var.public_key_path)}" : ""
  }

  network_interface {
    subnetwork = module.vpc_spoke1.subnets_self_links[0]
    #network_ip = cidrhost(var.cidr_spoke1, 10)
  }

  boot_disk {
    initialize_params {
      image = var.spoke_vm_image
    }
  }

  service_account {
    scopes = var.spoke_vm_scopes
  }
}


resource "google_compute_instance_group" "spoke1_ig" {
  name = "${local.prefix}spoke1-ig"
  zone = data.google_compute_zones.main.names[0]

  instances = google_compute_instance.spoke1_vm.*.id
}

module "spoke1_ilb" {
  source = "../../modules/lb_internal/"

  name       = "${local.prefix}spoke1-ilb"
  backends   = { 0 = google_compute_instance_group.spoke1_ig.self_link }
  ip_address = cidrhost(var.cidr_spoke1, 10)
  subnetwork = module.vpc_spoke1.subnets_self_links[0]
  network    = module.vpc_spoke1.network_id

  all_ports = false

  timeout_sec       = 1
  ports             = [80]
  health_check_port = 80

}


# --------------------------------------------------------------------------------------------------------------------------
# Create spoke2 compute instances. 

resource "google_compute_instance" "spoke2_vm1" {
  name                      = "${local.prefix}spoke2-vm1"
  machine_type              = var.spoke_vm_type
  zone                      = data.google_compute_zones.main.names[0]
  can_ip_forward            = false
  allow_stopping_for_update = true

  metadata = {
    serial-port-enable = true
    ssh-keys           = fileexists(var.public_key_path) ? "${var.spoke_vm_user}:${file(var.public_key_path)}" : ""
  }

  network_interface {
    subnetwork = module.vpc_spoke2.subnets_self_links[0]
    network_ip = cidrhost(var.cidr_spoke2, 10)
  }

  boot_disk {
    initialize_params {
      image = var.spoke_vm_image
    }
  }

  service_account {
    scopes = var.spoke_vm_scopes
  }

}