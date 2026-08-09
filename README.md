# My Azure Homelab: The Foundation

This repository contains the **foundational infrastructure** for my evolving homelab on Azure. 

I am building this project as a modular base layer. While the current setup focuses on establishing a robust, persistent Compute and Storage architecture, it is designed to be the bedrock for a much larger, more complex ecosystem that I am actively developing.

## 🚧 Status: Phase 1 (Core Infrastructure)

This is just the beginning. I have established the essential primitives—networking, state management, and persistence—to support the advanced capabilities (service meshes, managed databases, complex topologies) that will follow.

What I have solved so far:
- **Modular Autonomy**: Decoupling the lifecycle of "muscle" (Compute) from "memory" (Storage).
- **Hardened Persistence**: Ensuring data survival independent of infrastructure volatility.
- **Bootstrapping**: Automating the "Day 0" configuration of disposable nodes.

## 📚 Documentation

I have put comprehensive documentation under the `docs/` directory to help you understand this foundational layer:

- **[📖 Conceptual Guide](docs/conceptual_guide.md)**  
  *Read this first!* Here I explain the architectural philosophy I am using to prepare for scale, including:
  - Why I treat this early infrastructure as "Cattle, Not Pets".
  - My "Split Disk Strategy" for long-term data safety.
  - The `cloud-init` patterns I'm establishing for future flexibility.

- **[⚙️ Technical Reference](docs/technical_reference.md)**  
  My personal API reference for the current core modules.

- **[🔑 OIDC Bootstrap Runbook](docs/oidc_bootstrap.md)**  
  The one module I apply by hand: the managed identity my pipelines authenticate as, so no
  Azure password ever lives in GitHub.

## 🚀 Quick Start (The Base Layer)

### Prerequisites
- Azure CLI
- Terraform v1.x
- GitHub Account (for my CI/CD pipelines)

### Deployment Order
To lay this foundation, I deploy the modules in this specific dependency order:

**Note:** Ensure you have set the required secrets in GitHub and created `terraform.tfvars` locally (copy from `.example`).

0.  **Identity** (`infra/identity`) — *one-time bootstrap, local only*
    The managed identity my CI federates into for keyless OIDC auth. It cannot deploy itself
    through Actions (the credential it would need is the thing it creates), so I apply it by
    hand, once, and never from CI. Full procedure in the
    **[🔑 OIDC Bootstrap Runbook](docs/oidc_bootstrap.md)**.
    ```bash
    cd infra/identity
    terraform init
    terraform apply
    ```

1.  **Network** (`infra/network`)  
    Establishing the perimeter and address space.
    ```bash
    cd infra/network
    terraform init
    terraform apply
    ```

2.  **DNS** (`infra/dns`)
    Creating the Azure DNS Zone.
    ```bash
    cd ../../infra/dns
    terraform init
    terraform apply
    ```

3.  **Cloudflare** (`infra/cloudflare`)
    Delegating the subdomain to Azure DNS.
    ```bash
    cd ../../infra/cloudflare
    terraform init
    terraform apply
    ```

4.  **Storage** (`infra/storage`)  
    Provisioning the persistent data layer.
    ```bash
    cd ../../infra/storage
    terraform init
    terraform apply
    ```

5.  **Compute** (`compute/vm`)  
    Spinning up the initial workload node.
    ```bash
    cd ../../compute/vm
    terraform init
    terraform apply
    ```

### Verification
Once deployed, I verify that the core is healthy and persistent. See my **[✅ Verification Guide](docs/verification_guide.md)** for the procedure.

### CI/CD
I manage these core deployments via GitHub Actions in `.github/workflows/`.
