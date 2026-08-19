# Azure CloudOps Portfolio Lab

A cost-conscious Azure cloud engineering portfolio project designed to demonstrate practical Azure administration, Infrastructure as Code, serverless application hosting, monitoring, identity, storage, and CI/CD skills.

## Phase 1 architecture

```text
User
  |
  v
Azure Static Web Apps (Free)
  |
  v
Azure Functions (Flex Consumption, Python)
  |
  +--> Azure Table Storage (incidents)
  +--> Azure Blob Storage (future attachments)
  |
  v
Application Insights + Log Analytics

Terraform state --> separate Azure Storage Account
```

## What this repository demonstrates

- Terraform-based Azure provisioning
- Remote Terraform state in Azure Blob Storage
- Azure Static Web Apps
- Azure Functions Flex Consumption
- Microsoft Entra ID / Managed Identity
- Azure RBAC for data-plane access
- Azure Table Storage and Blob Storage
- Application Insights and Log Analytics
- Git/GitHub workflow and validation pipeline
- Cost-conscious architecture

## Repository layout

```text
app/
  api/                      Azure Functions Python API
  frontend/                 Vanilla HTML/CSS/JS frontend
infrastructure/
  bootstrap/                One-time Terraform state bootstrap
  environments/demo/        Persistent low-cost demo environment
scripts/
  deploy.ps1                Windows PowerShell deployment
  deploy.sh                 macOS/Linux deployment
docs/
  SETUP-DE.md               German step-by-step setup
.github/workflows/
  validate.yml              Basic CI validation
```

## Quick start

Read `docs/SETUP-DE.md` and then run the deployment script for your operating system.

Windows PowerShell:

```powershell
./scripts/deploy.ps1
```

macOS/Linux:

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

## Security design

The application code does not store Azure Storage account keys. The Function App uses its system-assigned Managed Identity and Azure RBAC (`Storage Table Data Contributor` and `Storage Blob Data Contributor`) for application data access.

The Function host deployment storage currently uses the Azure Functions Flex Consumption storage configuration supported by the AzureRM provider. A later hardening phase will evaluate identity-based host storage after the base deployment is stable.

## Cost design

The public demo is intentionally lightweight. The more expensive networking/container lab will live in a separate Terraform environment and will be created on demand and destroyed after testing.

## Roadmap

- [x] Phase 1 repository foundation
- [x] Terraform remote-state bootstrap
- [x] Serverless API
- [x] Static frontend
- [x] Storage + Managed Identity + RBAC
- [x] Monitoring foundation
- [ ] GitHub Actions OIDC deployment
- [ ] Key Vault
- [ ] Azure Budget and cost alerts
- [ ] VNet, NSG, Private DNS, Private Endpoint lab
- [ ] Azure Container Registry + Container Apps lab
- [ ] Azure Policy / governance lab
- [ ] Failure scenarios and troubleshooting runbooks
