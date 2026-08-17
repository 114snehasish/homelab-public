terraform {
  backend "azurerm" {
    resource_group_name  = "do-not-delete"
    storage_account_name = "listeninfratfstatesa"
    container_name       = "tfstate"

    # No `key` here on purpose (E17.4, #163): this is a *partial* backend
    # config so one module directory can serve several instances, each with
    # its own state blob. CI passes it as
    # `-backend-config="key=<state_key>"` from _terraform.yml. Locally:
    #
    #   terraform init -input=false -backend-config="key=homelab.compute.tfstate"
    #
    # and add -reconfigure when switching instances inside one checkout,
    # otherwise init reuses the cached backend of the previous instance.
    #
    # Hardcoding the key here *as well* would be worse than either option
    # alone: the file would carry a lie, and a bare `terraform init` would
    # silently target instance zero. compute/vm is the only module that does
    # this — the other five keep a literal key and pass no state_key.
  }
}
