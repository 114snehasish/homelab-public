# TEMPORARY — verification only for #163, deleted before merge.
#
# Exists to prove _terraform.yml can plan two instances of compute/vm
# concurrently: its own state key, its own concurrency group, its own sticky
# PR comment, and its own variables. instance_name is what makes the second
# leg's plan visibly distinct from the first's.
instance_name = "homelab-vm-canary"
