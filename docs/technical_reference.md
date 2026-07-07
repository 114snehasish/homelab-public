# Technical Reference: Core Infrastructure

This document serves as the technical API reference for the **current foundational modules** of my homelab. 

As I expand the lab, new modules will be added, but these core components provide the essential runtime environment.

---

## 1. Project Structure (Current State)

```
.
├── compute
│   └── vm          # [Ephemeral] The Workload Node
├── infra
│   ├── network     # [Persistent] The Network Backbone
│   └── storage     # [Persistent] The Data Layer
├── .github
│   └── workflows   # CI/CD Pipelines
└── docs            # Documentation
```

---

## 2. Core Module: `infra/network`

**Purpose**: Sets up the foundational networking perimeter. I designed this to be the stable backbone that future services will plug into.

### Resources
- `azurerm_resource_group.homelab_rg`: The logistical container for my resources.
- `azurerm_virtual_network.homelab_vnet`: The address space (10.0.0.0/16) reserved for the lab.
- `azurerm_subnet.homelab_subnet`: The initial subnet for compute nodes.
- `azurerm_network_security_group.homelab_nsg`: The security boundary.

---

## 3. Core Module: `infra/storage`

**Purpose**: Manages the persistent data assets. This is the "Vault" of my architecture.

### Resources
- `azurerm_managed_disk.homelab_data_disk`: The primary persistent store.
  - **Lifecycle**: Protected by `prevent_destroy = true`.
  - **Role**: currently hosts Docker data volumes; architected to exist independently of any specific compute instance.

---

## 4. Core Module: `compute/vm`

**Purpose**: The current execution environment. I designed this module to be highly disposable and replaceable.

### Resources
- `azurerm_linux_virtual_machine.homelab_vm`: The current Ubuntu host.
- `azurerm_virtual_machine_data_disk_attachment`: The dynamic link between the disposable VM and the persistent storage.

### Automation (`cloud-init.yaml`)
The bootstrapping script is designed to:
1.  Detect the persistent storage at **LUN 10**.
2.  Safely mount it to `/data` (avoiding destructive formatting).
3.  Initialize the container runtime.

---

## 5. CI/CD Workflows

### Per-module pipelines

Each module has its own workflow, runnable standalone (push with path filter, or manual dispatch) and callable as a reusable workflow (`workflow_call`):
- **`deploy-network.yml`**: Deploys the backbone.
- **`deploy-dns.yml`**: Creates the Azure DNS zone.
- **`deploy-cloudflare.yml`**: Delegates the subdomain from Cloudflare to Azure DNS.
- **`deploy-storage.yml`**: Provisions the vaults.
- **`deploy-compute.yml`**: Launches the nodes.
