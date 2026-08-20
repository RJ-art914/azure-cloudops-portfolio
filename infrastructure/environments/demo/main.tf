data "azurerm_client_config" "current" {}

locals {
  common_tags = merge(
    {
      project     = "azure-cloudops-portfolio"
      environment = var.environment
      managed_by  = "terraform"
      portfolio   = "true"
    },
    var.tags
  )
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "demo" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_storage_account" "app" {
  name                     = "st${var.project_name}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.demo.name
  location                 = azurerm_resource_group.demo.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "function_deployments" {
  name                  = "function-deployments"
  storage_account_id    = azurerm_storage_account.app.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "attachments" {
  name                  = "incident-attachments"
  storage_account_id    = azurerm_storage_account.app.id
  container_access_type = "private"
}

resource "azurerm_storage_table" "incidents" {
  name               = "incidents"
  storage_account_id = azurerm_storage_account.app.id
}

resource "azurerm_storage_table" "rate_limits" {
  name               = "ratelimits"
  storage_account_id = azurerm_storage_account.app.id
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.1
  tags                = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.main.id
  tags                = local.common_tags
}

resource "azurerm_service_plan" "functions" {
  name                = "asp-${var.project_name}-${var.environment}-fc"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.common_tags
}

resource "azurerm_static_web_app" "frontend" {
  name                = "swa-${var.project_name}-${var.environment}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = var.static_web_app_location
  sku_tier            = "Free"
  sku_size            = "Free"
  tags                = local.common_tags
}

resource "azurerm_function_app_flex_consumption" "api" {
  name                = "func-${var.project_name}-${var.environment}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  service_plan_id     = azurerm_service_plan.functions.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.app.primary_blob_endpoint}${azurerm_storage_container.function_deployments.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.app.primary_access_key

  runtime_name           = "python"
  runtime_version        = "3.12"
  maximum_instance_count = 3
  instance_memory_in_mb  = 2048

  app_settings = {
    APP_STORAGE_ACCOUNT_NAME              = azurerm_storage_account.app.name
    INCIDENTS_TABLE_NAME                  = azurerm_storage_table.incidents.name
    RATE_LIMITS_TABLE_NAME                = azurerm_storage_table.rate_limits.name
    WRITE_LIMIT_PER_HOUR                  = "30"
    MAX_REQUEST_BYTES                     = "8192"
    MAX_TITLE_LENGTH                      = "100"
    MAX_SERVICE_LENGTH                    = "80"
    MAX_DESCRIPTION_LENGTH                = "1000"
    ATTACHMENTS_CONTAINER_NAME            = azurerm_storage_container.attachments.name
    CORS_ALLOWED_ORIGIN                   = "https://${azurerm_static_web_app.frontend.default_host_name}"
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main.connection_string
  }

  identity {
    type = "SystemAssigned"
  }

  site_config {
    cors {
      allowed_origins = [
        "https://${azurerm_static_web_app.frontend.default_host_name}"
      ]
      support_credentials = false
    }
  }

  tags = local.common_tags
}

resource "azurerm_role_assignment" "function_table_data" {
  scope                = azurerm_storage_account.app.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.api.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_blob_data" {
  scope                = azurerm_storage_account.app.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.api.identity[0].principal_id
}

# Allows local development through `az login` and DefaultAzureCredential.
resource "azurerm_role_assignment" "developer_table_data" {
  scope                = azurerm_storage_account.app.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "developer_blob_data" {
  scope                = azurerm_storage_account.app.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
