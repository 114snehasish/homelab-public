variable "location" {
  type    = string
  default = "southindia"
}

variable "rg_name" {
  type    = string
  default = "homelab-rg"
}

variable "ssh_source_ip" {
  description = "The IP address allowed to SSH into the VM. If not provided, it defaults to the machine running Terraform."
  type        = string
  default     = null
}

variable "vnet_address_space" {
  description = "Address space of homelab-vnet. The tier allocation inside it is fixed by ADR-0012 (docs/adr/0012-workload-tiering-cidr-and-nsg-ownership.md); it must not be widened to overlap GCP's 10.1.0.0/24."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnets" {
  description = "Subnets to create in homelab-vnet, keyed by subnet name. Each key also names the NSG association created for it. Adding a tier is a map entry — see the CIDR plan in ADR-0012."
  type = map(object({
    address_prefixes = list(string)
  }))
  default = {
    "homelab-subnet" = {
      address_prefixes = ["10.0.0.0/24"]
    }
  }
}

variable "nsg_rules" {
  description = "Inbound/outbound rules on homelab-nsg-for-vm, keyed by rule name. priority is explicit on every entry: for_each iteration order must never decide a priority. Omit source_address_prefix to inherit the SSH whitelist default (var.ssh_source_ip, else the public IP of the machine running Terraform)."
  type = map(object({
    priority                   = number
    direction                  = string
    access                     = string
    protocol                   = string
    source_port_range          = string
    destination_port_range     = string
    source_address_prefix      = optional(string)
    destination_address_prefix = string
  }))
  default = {
    "Allow-SSH" = {
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      destination_address_prefix = "*"
    }
    # 80/443 are open to the internet on purpose (#37): this tier is the public
    # edge and Caddy (#39) is the only intended listener. 80 stays open for the
    # ACME HTTP-01 fallback and the redirect to HTTPS, not for plaintext apps.
    # source_address_prefix is explicit on both so they never inherit the SSH
    # whitelist default.
    "Allow-HTTP" = {
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "80"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
    "Allow-HTTPS" = {
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}
