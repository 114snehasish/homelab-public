# The fleet: one entry per compute node.
#
# This single file is the whole authoring surface for multiplicity. The map key
# IS the instance name — every name a node produces derives from it — so adding
# a node is one entry here and nothing else: no workflow edit, no new state key,
# no new concurrency group, no destroy.yml leg.
#
# Read by two modules through _terraform.yml's `var_file` input:
#   compute/vm     -> -var-file=../../fleet.tfvars   (VM, NIC, public IP, DNS A record, disk attachment)
#   infra/storage  -> -var-file=../fleet.tfvars      (one persistent data disk per node)
# Each module declares only the attributes it consumes and Terraform silently
# drops the rest, which is what lets one file serve both. The flip side: a
# misspelled attribute is ignored rather than rejected — read the plan.
#
# Committed on purpose (a .gitignore negation of the repo-wide *.tfvars rule),
# so NON-SECRET VALUES ONLY: main is force-mirrored to a public repo. Secrets
# keep arriving as TF_VAR_* from the workflow env.
#
# Adding a node is cheap now, which is not the same as justified: ADR-0012's
# "earns its own VM" test and #159's "default fleet stays at one node" still
# apply, and E09 (k3s, #22) may make a second VM unnecessary.

instances = {
  # The deployed node. Every default reproduces today's names byte-for-byte.
  homelab-vm = {
    # Pinned, and load-bearing: the existing disk is `homelab-data-disk`, not
    # `homelab-vm-data-disk`. New keys fall back to "${key}-data-disk"; letting
    # this one follow that pattern would be a rename, i.e. destroy-and-recreate
    # of the one resource that must never die. prevent_destroy turns that into
    # a plan error rather than data loss, but the pin is what avoids it.
    disk_name = "homelab-data-disk"
  }
}
