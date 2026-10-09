output "function_app_name" {
  value = azurerm_function_app_flex_consumption.hosting.name
}

output "function_app_id" {
  value = azurerm_function_app_flex_consumption.hosting.id
}

output "resource_group_name" {
  value = data.azurerm_resource_group.hosting.name
}

output "hosting_subscription_id" {
  value = var.hosting_subscription_id
}

output "api_url" {
  value = "https://${azurerm_function_app_flex_consumption.hosting.default_hostname}/api"
}

output "storage_account_name" {
  value = data.azurerm_storage_account.hosting.name
}

output "storage_blob_endpoint" {
  value = data.azurerm_storage_account.hosting.primary_blob_endpoint
}

output "source_identity_client_id" {
  value = data.azurerm_user_assigned_identity.source.client_id
}

output "target_identity_client_id" {
  value = data.azurerm_user_assigned_identity.target.client_id
}

output "private_endpoints_subnet_id" {
  value = azurerm_subnet.private_endpoints.id
}