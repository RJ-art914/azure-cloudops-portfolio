output "resource_group_name" {
  value = azurerm_resource_group.demo.name
}

output "storage_account_name" {
  value = azurerm_storage_account.app.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.api.name
}

output "api_base_url" {
  value = "https://${azurerm_function_app_flex_consumption.api.name}.azurewebsites.net/api"
}

output "static_web_app_name" {
  value = azurerm_static_web_app.frontend.name
}

output "frontend_url" {
  value = "https://${azurerm_static_web_app.frontend.default_host_name}"
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.main.name
}

output "application_insights_name" {
  value = azurerm_application_insights.main.name
}
