---
name: verify-persistence
description: Run the volume-persistence test from docs/verification_guide.md — write data to /data via a container, destroy ONLY compute/vm, re-apply, and verify the data survived on the new VM. Destroys and recreates the homelab VM.
disable-model-invocation: true
---

Prove that destroying the VM does not destroy the data disk ("cattle VM, pet disk"). Follows @docs/verification_guide.md.

Prerequisites: `infra/network`, `infra/storage`, and `compute/vm` are applied; Azure creds loaded (`set -a; source .env; set +a`); SSH access works from this machine (the NSG whitelists the IP that last ran the network apply).

`compute/vm` uses a partial backend config (E17.4, #163), so initialize it with its state key
before any `output`/`destroy`/`apply` below — a bare `init` there fails:

```bash
terraform -chdir=compute/vm init -input=false -backend-config="key=homelab.compute.tfstate"
```

## Steps

1. **Get connection info**: `terraform -chdir=compute/vm output -json ssh_command | jq -r '."homelab-edge"'` — the outputs are **maps keyed by instance name** now that the module builds a fleet.
2. **Seed persistent data** over SSH:
   ```bash
   df -h /data                     # confirm the 20GB disk is mounted
   sudo docker run -d --name test-redis -v /data/redis:/data redis
   sudo docker exec test-redis sh -c "echo 'Volume Persistence Works' > /data/persistence_check.txt"
   ```
3. **Confirm with the user before this step, showing the plan** — then destroy ONLY the compute module:
   ```bash
   terraform -chdir=compute/vm destroy -auto-approve -var-file=../../fleet.tfvars \
     -target='azurerm_linux_virtual_machine.homelab_vm["homelab-edge"]' \
     -target='azurerm_virtual_machine_data_disk_attachment.data_disk_attachment["homelab-edge"]'
   ```
   Never touch `infra/storage` (its disks have `prevent_destroy`) or any other module.

   **Target one node.** `compute/vm` now builds every entry in `fleet.tfvars` with `for_each`, so
   an untargeted `destroy` here tears down the **whole fleet**. While the fleet is one node the
   two are the same thing; the moment it is not, the untargeted form is a mistake. (Removing the
   entry from `fleet.tfvars` and applying is the other way to retire one node — that one is
   permanent, which is not what this test wants.)
4. **Recreate**: `terraform -chdir=compute/vm apply -auto-approve -var-file=../../fleet.tfvars`. Wait for cloud-init (`cloud-init status --wait`), then confirm the mount contract (#99): `systemctl is-active homelab-persist.target` prints `active`, and `journalctl -b -u 'homelab-persist-prepare@*' -u 'homelab-data-guard@*'` shows prepare finding the existing ext4 **without formatting** and the guard printing `OK`.
5. **Verify survival** on the new VM. Docker's storage lives on `/data` since #99, so `docker ps -a` still lists `test-redis` — expected, not stale state:
   ```bash
   sudo docker run -d --name test-redis-2 -v /data/redis:/data redis
   sudo docker exec test-redis-2 cat /data/persistence_check.txt
   ```

**Success**: the final command prints `Volume Persistence Works`.

## Cleanup and report

Remove the test containers (`sudo docker rm -f test-redis test-redis-2` — both exist, since containers now survive the recreate) and optionally `/data/redis`. Report pass/fail, the old vs. new public IP, and anything unexpected in the prepare/guard journal (`journalctl -b -u 'homelab-persist-prepare@*' -u 'homelab-data-guard@*'`).
