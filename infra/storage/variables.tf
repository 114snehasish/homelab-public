variable "rg_name" {
  type    = string
  default = "homelab-rg"
}

variable "location" {
  type    = string
  default = "southindia"
}

variable "disk_name" {
  type    = string
  default = "homelab-data-disk"
}

variable "disk_size_gb" {
  type    = number
  default = 20 # Adjust size as needed
}
