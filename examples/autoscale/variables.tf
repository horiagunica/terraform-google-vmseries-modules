# variable "project_id" {
#   description = "GCP Project ID"
#   type        = string
# }

# variable "auth_file" {
#   description = "GCP Project auth JSON file"
#   type        = string
# }

# variable region {
#   description = "GCP Region"
#   default     = "europe-west4"
#   type        = string
# }

variable public_key_path {
  description = "Local path to public SSH key. To generate the key pair use `ssh-keygen -t rsa -C admin -N '' -f id_rsa`  If you do not have a public key, run `ssh-keygen -f ~/.ssh/demo-key -t rsa -C admin`"
  default     = "id_rsa.pub"
}

variable fw_panos {
  description = "VM-Series license and PAN-OS version (ie: bundle1-814, bundle2-814, or byol-814)"
  default     = "byol-912"
}

variable fw_image {
  default = "https://www.googleapis.com/compute/v1/projects/paloaltonetworksgcp-public/global/images/vmseries"
}

variable fw_machine_type {
  default = "n1-standard-4"
}

variable prefix {
  description = "Prefix to GCP resource names, an arbitrary string"
  default     = "as4"
  type        = string
}

variable extlb_name {
  default = "as4-fw-extlb"
}

variable extlb_healthcheck_port {
  type    = number
  default = 80
}

variable intlb_name {
  default = "as4-fw-intlb"
}

variable mgmt_sources {
  default = ["0.0.0.0/0"]
  type    = list(string)
}

variable networks {
  description = "The list of maps describing the VPC networks and subnetworks"
}

variable autoscaler_metric_name {
  default = "custom.googleapis.com/VMSeries/panSessionActive"
}

variable autoscaler_metric_type {
  default = "GAUGE"
}

variable autoscaler_metric_target {
  default = 100
}

variable service_account {
  description = "IAM Service Account for running firewall instances (just the identifier, without `@domain` part)"
  default     = null
  type        = string
}
