# Per-instance variables for `compute/vm`

One file per compute instance, passed to `terraform plan` as `-var-file` by
`_terraform.yml`'s `var_file` input (E17.4, [#163](https://github.com/114snehasish/homelab/issues/163)).
The path is resolved relative to `compute/vm`, so a matrix entry references
`instances/<name>.tfvars`.

`.gitignore` ignores `*.tfvars` repo-wide and un-ignores this directory
specifically — these files are *meant* to be committed, which means:

- **Non-secret values only.** `main` is force-mirrored to a public GitHub repo
  (`mirror.yml`), so no keys, no tokens, no per-host detail. Secrets keep
  arriving as `TF_VAR_*` from the workflow's `env:` block.
- `-var-file` **outranks** an env-set `TF_VAR_*`, so an entry here overrides the
  shared value for that variable — that is the point of the mechanism, and also
  the way to shoot yourself in the foot with it.
- The state key is **not** set here. It is a matrix field in
  `deploy-compute.yml`, because it selects the backend before variables are
  read at all.

## The existing node has no file here, deliberately

`homelab-vm` runs on the module defaults (`instance_name = "homelab-vm"`, and
every produced name derives from it since
[#162](https://github.com/114snehasish/homelab/issues/162)) plus the shared
`TF_VAR_dns_zone_name`/`TF_VAR_dns_rg_name` values. Adding a file that merely
restates the defaults would be a second place to keep them correct.

## Adding one

```hcl
# instances/<name>.tfvars
instance_name = "homelab-tools"
vm_size       = "Standard_B2s"
```

Then add a matrix entry in `.github/workflows/deploy-compute.yml` with a state
key no other entry uses:

```yaml
- name: homelab-tools
  state_key: homelab.compute.tools.tfstate
  var_file: instances/homelab-tools.tfvars
```

A second node is gated on ADR-0012's "earns its own VM" test and on
[#165](https://github.com/114snehasish/homelab/issues/165) (a managed disk
cannot attach to two VMs) — see [#166](https://github.com/114snehasish/homelab/issues/166).
