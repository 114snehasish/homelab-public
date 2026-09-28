# custom_data for every node: cloud-init.yaml plus the mount contract v2 (#99),
# assembled here rather than templated.
#
# Why not templatefile(): the contract is mostly shell, and shell's ${VAR} is
# Terraform's interpolation syntax, so every expansion would need escaping as
# $${VAR} and a missed one fails the render with an error that never mentions
# escaping. Instead cloud-init.yaml is parsed with yamldecode(), the contract's
# files are appended to its write_files verbatim with file(), and the result is
# re-encoded with yamlencode(). No file is ever read as a template, so the trap
# does not exist rather than being escaped around.
#
# Only two things are rendered per node: one .mount unit per (LUN -> mount)
# entry, and homelab-persist.target, which requires every guard. Whatever decides
# if a disk is formatted, mounted or trusted lives in persist/ and in
# scripts/write-persist-marker.sh, identical on every node.
#
# custom_data is ForceNew: changing ANY file listed here replaces the VM on the
# next apply. scripts/write-persist-marker.sh lives outside this module, which is
# why deploy-compute.yml path-filters it explicitly.

locals {
  # The (LUN -> mount point) set each node's contract mounts and guards. One
  # entry today, from the node's data_disk_lun. E17.6 (#165) swaps this
  # expression for a per-instance map; nothing below it changes.
  #
  # Mount points must stay plain absolute paths of [a-z0-9] segments: unit names
  # are derived by replacing "/" with "-", which only matches
  # `systemd-escape --path` for paths like that.
  persist_mounts = {
    for name, inst in var.instances : name => {
      (tostring(inst.data_disk_lun)) = "/data"
    }
  }

  persist_units = {
    for name, mounts in local.persist_mounts : name => [
      for lun, mount in mounts : {
        lun     = lun
        mount   = mount
        escaped = replace(trimprefix(mount, "/"), "/", "-")
      }
    ]
  }

  # The contract's static files: path on the VM => source, relative to this
  # module. An explicit map rather than fileset(): a glob would also ship
  # whatever else lands in the directory (an editor backup, a .DS_Store),
  # silently changing custom_data and replacing every VM.
  persist_files = {
    "/usr/local/sbin/write-persist-marker.sh"                          = { source = "../../scripts/write-persist-marker.sh", mode = "0755" }
    "/usr/local/sbin/homelab-persist-prepare"                          = { source = "persist/homelab-persist-prepare.sh", mode = "0755" }
    "/usr/local/sbin/homelab-data-guard"                               = { source = "persist/homelab-data-guard.sh", mode = "0755" }
    "/etc/systemd/system/homelab-persist-prepare@.service"             = { source = "persist/homelab-persist-prepare@.service", mode = "0644" }
    "/etc/systemd/system/homelab-data-guard@.service"                  = { source = "persist/homelab-data-guard@.service", mode = "0644" }
    "/etc/systemd/system/docker.service.d/10-homelab-persist.conf"     = { source = "persist/docker.service.d/10-homelab-persist.conf", mode = "0644" }
    "/etc/systemd/system/containerd.service.d/10-homelab-persist.conf" = { source = "persist/containerd.service.d/10-homelab-persist.conf", mode = "0644" }
    "/etc/docker/daemon.json"                                          = { source = "persist/daemon.json", mode = "0644" }
  }

  # The backup contract's static files (#100), same explicit-map discipline as
  # persist_files above and for the same reason: a fileset() glob would also ship
  # an editor backup or a .DS_Store, silently changing custom_data and replacing
  # every VM.
  #
  # Shipped ONLY to the node with public_edge = true, because only that node
  # carries the backup identity infra/identity created and compute/vm attaches. A
  # private-tier node getting these files would get timers that cannot
  # authenticate — a nightly failure with no way to succeed.
  restic_files = {
    "/usr/local/sbin/restic-backup"                     = { source = "backup/restic-backup.sh", mode = "0755" }
    "/usr/local/sbin/restic-check"                      = { source = "backup/restic-check.sh", mode = "0755" }
    "/etc/homelab/restic-excludes"                      = { source = "backup/restic-excludes", mode = "0644" }
    "/etc/homelab/backup-pre.d/README"                  = { source = "backup/backup-pre.d/README", mode = "0644" }
    "/etc/systemd/system/homelab-restic-backup.service" = { source = "backup/homelab-restic-backup.service", mode = "0644" }
    "/etc/systemd/system/homelab-restic-backup.timer"   = { source = "backup/homelab-restic-backup.timer", mode = "0644" }
    "/etc/systemd/system/homelab-restic-check.service"  = { source = "backup/homelab-restic-check.service", mode = "0644" }
    "/etc/systemd/system/homelab-restic-check.timer"    = { source = "backup/homelab-restic-check.timer", mode = "0644" }
  }

  # The one file here that cannot be a static source: AZURE_CLIENT_ID is a
  # Terraform attribute of the identity this module attaches, so it is rendered
  # per node.
  #
  # Every value in it is an IDENTIFIER, not a credential — a client id, an account
  # name, two paths. The only secret involved is the repository password, which is
  # a file on the data disk placed out of band (R13). That is what keeps this
  # whole file safe to live in custom_data, which is readable by anyone who can
  # read the VM resource.
  #
  # 0640 root:root rather than 0644: nothing on this box needs to read it but
  # root, and AZURE_CLIENT_ID selecting an identity is not something an
  # unprivileged process should be able to enumerate.
  restic_env = {
    for name in local.public_edge_instances : name => <<-EOT
      # Rendered by compute/vm/cloud-init.tf (#100). Sourced by
      # /usr/local/sbin/restic-backup and /usr/local/sbin/restic-check, so a
      # manual run and the systemd timer see exactly the same environment.
      #
      # AZURE_CLIENT_ID is load-bearing: this node carries TWO user-assigned
      # managed identities (Caddy's DNS-01 identity and this one), which makes an
      # unpinned managed-identity token request ambiguous. It is exported into the
      # restic process only — system-wide it would leak into Caddy's container and
      # select the wrong identity there.
      #
      # There is no account key and no SAS: homelabpersistbackupsa sets
      # shared_access_key_enabled = false, so Entra is the only way in.
      AZURE_ACCOUNT_NAME=${var.backup_storage_account_name}
      AZURE_CLIENT_ID=${data.azurerm_user_assigned_identity.backup[name].client_id}
      RESTIC_REPOSITORY=azure:${var.restic_container_name}:/
      RESTIC_PASSWORD_FILE=/data/.restic-password
      # On the pet disk on purpose: the OS disk is destroyed on every park, so a
      # cache there is rebuilt from scratch on every resume (#207 owns its sizing).
      RESTIC_CACHE_DIR=/data/.cache/restic
    EOT
  }

  cloud_init_base = {
    for name, inst in var.instances : name => yamldecode(file("${path.module}/${inst.cloud_init_file}"))
  }

  # Iteration variables below are `dest` and `u`, never `path`: a variable named
  # path would shadow path.module inside the same expression.
  cloud_init = {
    for name, base in local.cloud_init_base : name => join("\n", [
      "#cloud-config",
      yamlencode(merge(base, {
        write_files = concat(
          try(base.write_files, []),
          [for dest, f in local.persist_files : {
            path        = dest
            owner       = "root:root"
            permissions = f.mode
            content     = file("${path.module}/${f.source}")
          }],
          [for u in local.persist_units[name] : {
            path        = "/etc/systemd/system/${u.escaped}.mount"
            owner       = "root:root"
            permissions = "0644"
            content     = <<-EOT
              # Rendered by compute/vm/cloud-init.tf (#99): the data disk at LUN ${u.lun}, on ${u.mount}.
              [Unit]
              Description=Homelab persistence: data disk at LUN ${u.lun} on ${u.mount}
              Documentation=https://github.com/114snehasish/homelab/blob/main/docs/runbooks/data_guard.md
              Requires=homelab-persist-prepare@${u.lun}.service
              After=homelab-persist-prepare@${u.lun}.service
              # Out of early boot on purpose: ordered after local-fs.target rather than
              # before it, so a missing disk can never hold up or fail the boot, only
              # the services that require homelab-persist.target.
              DefaultDependencies=no
              After=local-fs.target
              Conflicts=umount.target
              Before=umount.target

              [Mount]
              # prepare's link to the partition it vetted, not /dev/disk/azure/scsi1/lun${u.lun}-part1:
              # a What= under /dev gets a systemd device job with its own 90 s timeout,
              # which fails this mount when the disk attaches late but inside prepare's
              # 300 s wait. A path outside /dev gets no device job.
              What=/run/homelab-persist/lun${u.lun}-part1
              Where=${u.mount}
              Type=ext4
              Options=defaults
            EOT
          }],
          # Edge-only: an empty list for every other node (#100).
          [for dest, f in local.restic_files : {
            path        = dest
            owner       = "root:root"
            permissions = f.mode
            content     = file("${path.module}/${f.source}")
          } if contains(local.public_edge_instances, name)],
          [for n, content in local.restic_env : {
            path        = "/etc/homelab/restic.env"
            owner       = "root:root"
            permissions = "0640"
            content     = content
          } if n == name],
          [{
            path        = "/etc/systemd/system/homelab-persist.target"
            owner       = "root:root"
            permissions = "0644"
            content     = <<-EOT
              # Rendered by compute/vm/cloud-init.tf (#99). Active only when every data disk
              # is mounted and has passed its data-guard. docker.service and
              # containerd.service require it; restic (#100) and k3s volumes (#103) will too.
              [Unit]
              Description=Homelab persistence: every data disk mounted and verified
              Documentation=https://github.com/114snehasish/homelab/blob/main/docs/runbooks/data_guard.md
              Requires=${join(" ", [for u in local.persist_units[name] : "homelab-data-guard@${u.escaped}.service"])}
              After=${join(" ", [for u in local.persist_units[name] : "homelab-data-guard@${u.escaped}.service"])}

              [Install]
              WantedBy=multi-user.target
            EOT
          }],
        )
      })),
    ])
  }
}
