# ADR-0012: Workload tiering, CIDR plan, and NSG ownership

- **Status**: Accepted — section 5 (egress comparison) is a deliberate stub until [#164](https://github.com/114snehasish/homelab/issues/164) and [#169](https://github.com/114snehasish/homelab/issues/169) are built and measured
- **Date**: 2026-08-13
- **Deciders**: repo owner
- **Related**: [#159](https://github.com/114snehasish/homelab/issues/159) (E17, parent) · [#160](https://github.com/114snehasish/homelab/issues/160) (this ADR) · [#161](https://github.com/114snehasish/homelab/issues/161) · [#162](https://github.com/114snehasish/homelab/issues/162) · [#164](https://github.com/114snehasish/homelab/issues/164) · [#169](https://github.com/114snehasish/homelab/issues/169) · [#37](https://github.com/114snehasish/homelab/issues/37) · [#38](https://github.com/114snehasish/homelab/issues/38) · [#39](https://github.com/114snehasish/homelab/issues/39) · [#99](https://github.com/114snehasish/homelab/issues/99) · [#108](https://github.com/114snehasish/homelab/issues/108) · [#54](https://github.com/114snehasish/homelab/issues/54) · [#22](https://github.com/114snehasish/homelab/issues/22)

## Context

Every module in this repo builds exactly one of each resource. `infra/network` hardcodes
the VNet as `10.0.0.0/16` and a single subnet as `10.0.0.0/24` — no CIDR variables, no
`cidrsubnet()`. `compute/vm` parameterizes every name it *consumes* and zero names it
*produces*. The whole repo holds one `for_each` and zero `count`.

E17 makes multiplicity possible. Before any of it is built, four things have to be
decided on paper, because three issues already scheduled ahead of E17 — [#38](https://github.com/114snehasish/homelab/issues/38)
(wildcard DNS), [#39](https://github.com/114snehasish/homelab/issues/39) (Caddy edge) and
[#99](https://github.com/114snehasish/homelab/issues/99) (mount contract) — will otherwise
bake in single-VM assumptions that then have to be torn up. This ADR is the cheapest
child of E17 and the one with the highest cost of being skipped.

Two constraints frame everything below:

- **The default fleet stays at one node.** `Standard_B4ms` (16 GB) was chosen precisely
  to fit compose apps + monitoring + k3s on one box, and E09 ([#22](https://github.com/114snehasish/homelab/issues/22))
  is the workload-isolation story. Additional nodes are opt-in map entries, not a
  deployment shape.
- **The drivers are topology learning, blast-radius isolation and per-workload park
  granularity** — explicitly *not* resource contention.

## Decision

### 1. CIDR allocation

Azure keeps `10.0.0.0/16`. It is subdivided into named `/24` tiers on paper now, even
though only the first exists:

| Tier | CIDR | Holds | Exists today |
|---|---|---|---|
| public | `10.0.0.0/24` | today's `homelab-subnet` — the internet-facing edge (Caddy) | **yes**, unchanged |
| private | `10.0.1.0/24` | workload nodes with no public IP, reached over the tailnet | no — [#164](https://github.com/114snehasish/homelab/issues/164) |
| data | `10.0.2.0/24` | reserved: databases, if they ever leave the app node | no |
| reserved | `10.0.3.0/24`+ | future — AKS node pool ([#83](https://github.com/114snehasish/homelab/issues/83)), k3s agents | no |

**Reconciliation with GCP.** [#108](https://github.com/114snehasish/homelab/issues/108)
allocates GCP `10.1.0.0/24`, deliberately outside Azure's `10.0.0.0/16`. That non-overlap
is a decision, not a coincidence: it keeps a future site-to-site or tailnet-subnet-router
path between the two clouds routable without NAT or renumbering. Neither side may be
summarized into a range that swallows the other — in particular Azure must not widen
`10.0.0.0/16` to `10.0.0.0/15`, which would absorb GCP's space.

**What this ADR does not do.** [#161](https://github.com/114snehasish/homelab/issues/161)
turns `infra/network`'s subnet into a map with exactly one entry — today's — and shows a
zero-change plan. The private tier is created in Phase 2 ([#164](https://github.com/114snehasish/homelab/issues/164)),
which is hard-gated on Tailscale ([#54](https://github.com/114snehasish/homelab/issues/54)):
a private subnet built before the tailnet needs a bastion host to reach it; built after,
the tailnet *is* the access path.

### 2. NSG ownership belongs to the subnet

The NSG `homelab-nsg-for-vm` is currently associated at **both** layers:

- `azurerm_subnet_network_security_group_association.homelab_nsg_assoc` in `infra/network/main.tf`
- `azurerm_network_interface_security_group_association.vm_nsg_assoc` in `compute/vm/main.tf`

Azure permits both, and effective rules are the intersection — but a rule change then
affects two planes, and a multi-tier design needs exactly one owner per tier.

**Decision: the subnet is the owner.** Rules are a property of the tier a node sits in,
not of the node. A per-node exception, if one is ever genuinely needed, is an argument
for a new tier rather than for reinstating NIC-level rules.

**Removal of the NIC-level association is [#162](https://github.com/114snehasish/homelab/issues/162)'s
work (E17.3), not [#161](https://github.com/114snehasish/homelab/issues/161)'s.** #161 is a
zero-change refactor of `infra/network` and does not touch `compute/vm`.

### 3. The "earns its own VM" test

A second node is justified only when a workload can demonstrate **at least one** of the
following, and the demonstration is checkable by someone else:

1. **Kernel or OS incompatibility.** It needs a kernel version, module, distro or
   `sysctl` the app node cannot provide without disrupting what already runs there.
   *Evidence: the specific requirement, and what breaks on the app node.*
2. **A trust boundary k3s cannot express.** The isolation required is not achievable with
   namespaces, resource limits and NetworkPolicy (E09, [#22](https://github.com/114snehasish/homelab/issues/22)) —
   e.g. it must not share a kernel with other workloads.
   *Evidence: the specific attack or failure that a namespace boundary does not stop.*
3. **Independent lifecycle.** It must be up while the app node is parked, or parked while
   the app node is up. Per-workload park granularity is an E17 driver.
   *Evidence: the two schedules, and why they cannot coincide.*
4. **A booked topology experiment.** Learning a networking or fleet behaviour is a valid
   reason, but only as a one-off with a written retirement date in the issue.
   *Evidence: the issue number and the date the node comes down.*

Explicit **non-**drivers, each of which has failed this test by definition:

- **Resource contention.** Not a driver for this epic ([#159](https://github.com/114snehasish/homelab/issues/159)).
  The answer to "the box is full" is resizing or k3s scheduling, not a second pet.
- **Tidiness.** "It feels cleaner to separate it" is not evidence.
- **Because the epic made it possible.** Multiplicity is a capability, not a plan.

A node that no longer satisfies the clause it was created under should be removed —
under the map model that is deleting one entry.

### 4. Known expiries

Assumptions that are correct today and will break with a fleet. Each is owned by an
existing issue; none of them blocks that issue from shipping as designed.

| Assumption | Owner | Status under this ADR |
|---|---|---|
| Wildcard `*.az` resolves to **one** VM's public IP | [#38](https://github.com/114snehasish/homelab/issues/38) | **Does not expire.** Given the sole-edge decision below, the wildcard keeps pointing at the single public node and needs no change in Phase 2. |
| Caddy is the **single** public edge | [#39](https://github.com/114snehasish/homelab/issues/39) | **Decided: it stays the single edge** (below). |
| Mount contract is one LUN → one mount point | [#99](https://github.com/114snehasish/homelab/issues/99) | **Expires in E17.6** ([#165](https://github.com/114snehasish/homelab/issues/165)). Shape the v2 contract for a set now. |

**Caddy stays the sole public edge.** Private-tier nodes have no public IP and no TLS
terminator of their own; Caddy reverse-proxies to them over the VNet (or the tailnet).
Consequences that follow directly:

- Phase 2 needs **no internal load balancer** — a reverse-proxy upstream is a private
  IP, not a VIP.
- One wildcard cert, one ACME account, one cert store on `/data`. This preserves the
  hostname-hygiene property #39 was designed around (no per-app CT-log entries, R6).
- The public tier holds exactly one node. A second node in `10.0.0.0/24` needs its own
  justification under the test above, not just a public IP.
- Cost of the choice: the edge is a single point of failure for all ingress, and every
  private-node request traverses it. Accepted — a lab with one public IP already has
  that property.

**The mount contract ([#99](https://github.com/114snehasish/homelab/issues/99)).**
`compute/vm/cloud-init.yaml` hardcodes `lun10` → `/data`, and `compute/vm/main.tf` loads
it with `filebase64()`, **not** `templatefile()` — so it takes no per-instance
interpolation at all. A managed disk cannot attach to two VMs, so `infra/storage` must
multiply in lockstep with `compute/vm` (E17.6). If #99's rewrite lands hardcoded to a
single LUN/mount pair, it gets rewritten a second time; writing it against a
**(LUN → mount point) set** with one entry costs the same today. Note that switching to
`templatefile()` makes the file's shell `${DISK}1` an interpolation that must be escaped
`$${DISK}1`.

### 5. Egress comparison — STUB, do not fill from estimates

> **This section is intentionally empty.** It is filled in only after both egress paths
> have been built and *measured*: NAT Gateway ([#164](https://github.com/114snehasish/homelab/issues/164))
> first, then the UDR + NAT-instance path ([#169](https://github.com/114snehasish/homelab/issues/169))
> that replaces it. A decision record written from projections is exactly what this
> section exists to prevent — if it is still a stub, the ADR is not done.

A private node has no public IP, so it needs an explicit outbound path. Rather than
choosing one on paper, both get built — they fail differently, and the contrast is the
point. The gateway is managed, so a private tier that does not work points at the
subnet/NSG/routing rather than being confounded with a hand-rolled NVA; the NAT instance
then replaces it and the gateway resources are **deleted**, not kept as a toggle.

Axes to record, from observation:

| Axis | NAT Gateway (#164) | UDR + NAT instance (#169) |
|---|---|---|
| Cost (measured, ₹/mo) | _pending_ | _pending_ |
| Failure modes | _pending_ | _pending_ |
| Operational complexity | _pending_ | _pending_ |
| Egress IP behaviour observed | _pending_ | _pending_ |
| Steady state? | _pending_ | _pending_ |

Two things are already known and are recorded here so the measurement is not misread:

- **The bypass trap.** A UDR sending `0.0.0.0/0` to an NVA silently bypasses NAT Gateway:
  route selection is UDR > BGP > system routes, and NAT Gateway is not a routing
  construct. Both can exist while only one carries traffic — and the unused gateway still
  bills. **Verification is by observed egress IP, never by resource presence.**
- **Open question for #164 to answer by observation:** `homelab-vnet` predates the
  retirement of Azure's default outbound access. Whether a *newly created* subnet in it
  still inherits default outbound is unknown. Do not build on it either way — but record
  which behaviour a test is showing, or a working private node will be credited to the
  egress path under test when it was actually default outbound.

## Consequences

- **Positive.** The CIDR map is fixed before the first extra subnet exists, so no
  renumbering later. #37, #38, #39 and #99 can ship as designed with their expiry (or
  lack of one) written down. NSG changes have one owner, so #37's 80/443 rules land in
  one place.
- **Cost of the sole-edge decision.** All ingress funnels through one node; the public
  tier is capped at one node by convention rather than by mechanism.
- **Cost of paper allocation.** Three of the four tiers are documentation only. If a tier
  is never built, the `/24` reservation cost nothing; if the design changes, this ADR is
  superseded rather than edited.
- **Incomplete by design.** Section 5 is a stub. Anyone reading this ADR to choose an
  egress path before #164 and #169 land will find no answer here — that is intentional.
- **Public mirror (R6).** `main` is force-mirrored publicly, so this tier model and CIDR
  plan are public. RFC1918 space is not a secret; per-host detail stays out of the repo.

## Open items

- [ ] Fill section 5 with measured numbers after [#164](https://github.com/114snehasish/homelab/issues/164) and [#169](https://github.com/114snehasish/homelab/issues/169) (then flip Status to plain *Accepted*).
- [ ] Answer the default-outbound question during [#164](https://github.com/114snehasish/homelab/issues/164).
- [ ] Remove the NIC-level NSG association in [#162](https://github.com/114snehasish/homelab/issues/162).
