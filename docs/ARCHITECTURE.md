# Architecture

## Persistent demo environment

The first deployment intentionally keeps the architecture small and cost-conscious:

```text
Browser
   |
   v
Azure Static Web Apps (Free)
   |
   v
Azure Functions Flex Consumption
   |
   |-- Managed Identity --> Azure Table Storage
   |-- Managed Identity --> Azure Blob Storage
   |
   v
Application Insights
   |
   v
Log Analytics Workspace
```

Terraform state is stored separately:

```text
Terraform CLI
   |
   v
Azure Storage Account
   |
   v
private tfstate container
```

## Later lab environment

The next phases will add an on-demand lab with VNet, NSG, Private Endpoints, Private DNS, Azure Container Registry and Azure Container Apps. That environment will be destroyable after each learning session.
