# Deliberately not called `rg_name`: infra/network (which creates the RG),
# infra/storage and compute/vm all declare a variable by that name, so a
# TF_VAR_rg_name in CI would set this module's value and silently override
# those three modules' defaults at the same time. _terraform.yml used to work
# around that with a step gated to infra/dns; naming the variable for what it
# actually is — the RG holding the DNS zone, exactly as compute/vm means it —
# lets both modules share the one static TF_VAR_dns_rg_name entry instead.
# Same reasoning as infra/identity's homelab_rg_name.
variable "dns_rg_name" {
  description = "The Resource Group name where Azure DNS Zone resides"
  type        = string
  default     = "homelab-rg"
}

variable "dns_zone_name" {
  description = "The DNS zone name"
  type        = string
}
