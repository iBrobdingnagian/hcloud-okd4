variable "replicas_master" {
  type        = number
  default     = 1
  description = "Count of master replicas"
  validation {
    condition     = contains([1, 3, 5], var.replicas_master)
    error_message = "Master replicas must be 1, 3, or 5."
  }
}

variable "replicas_worker" {
  type        = number
  default     = 0
  description = "Count of worker replicas"
  validation {
    condition     = var.replicas_worker >= 0 && floor(var.replicas_worker) == var.replicas_worker
    error_message = "Worker replicas must be a nonnegative integer."
  }
}

variable "cluster_id" {
  type        = string
  default     = ""
  description = "Stable ownership ID for named clusters; empty preserves legacy ownership."
  validation {
    condition     = var.cluster_id == "" || can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_id))
    error_message = "cluster_id must be a lowercase name of at most 31 characters."
  }
}

variable "bootstrap" {
  type        = bool
  default     = false
  description = "Whether to deploy a bootstrap instance"
}

variable "dns_domain" {
  type        = string
  description = "Name of the Cloudflare domain"
}

variable "dns_zone_id" {
  type        = string
  description = "Zone ID of the Cloudflare domain"
}

variable "ip_loadbalancer_api" {
  description = "IP of an external loadbalancer for api (optional)"
  default     = null
}

variable "ip_loadbalancer_api_int" {
  description = "IP of an external loadbalancer for api-int (optional)"
  default     = null
}

variable "ip_loadbalancer_apps" {
  description = "IP of an external loadbalancer for apps (optional)"
  default     = null
}

variable "network_cidr" {
  type        = string
  description = "CIDR for the network"
  default     = "192.168.0.0/16"
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR for the subnet"
  default     = "192.168.254.0/24"
}

variable "lb_subnet_cidr" {
  type        = string
  description = "CIDR for the loadbalancer subnet"
  default     = "192.168.253.0/24"
}

variable "location" {
  type        = string
  description = "Region"
  default     = "nbg1"
}

variable "image" {
  type        = string
  description = "Image selector (either fcos or rhcos)"
  default     = "fcos"
}

variable "server_type_master" {
  type        = string
  description = "Server type for master nodes"
  default     = "cpx41"
}

variable "server_type_worker" {
  type        = string
  description = "Server type for worker nodes"
  default     = "cpx41"
}

variable "server_type_bootstrap" {
  type        = string
  description = "Server type for the bootstrap node"
  default     = "cpx41"
}

variable "server_type_ignition" {
  type        = string
  description = "Server type for the ignition node"
  default     = "cpx21"
}

variable "network_zone" {
  type        = string
  description = "Hetzner network zone the subnets are created in (eu-central, us-east, us-west, ap-southeast)"
  default     = "eu-central"
}

variable "fcos_release" {
  type        = string
  description = "Pin the CoreOS snapshot to this release label (empty = most recent snapshot)"
  default     = ""
}
