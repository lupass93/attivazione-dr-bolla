terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.49.0, < 6.0.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id     = var.hosting_subscription_id
  storage_use_azuread = true
}

data "azurerm_resource_group" "hosting" {
  name = var.resource_group_name
}

data "azurerm_storage_account" "hosting" {
  name                = var.storage_account_name
  resource_group_name = coalesce(var.storage_resource_group_name, var.resource_group_name)
}

data "azurerm_user_assigned_identity" "source" {
  name                = var.source_identity_name
  resource_group_name = coalesce(var.source_identity_resource_group_name, var.resource_group_name)
}

data "azurerm_user_assigned_identity" "target" {
  name                = var.target_identity_name
  resource_group_name = coalesce(var.target_identity_resource_group_name, var.resource_group_name)
}

resource "azurerm_virtual_network" "hosting" {
  name                = lookup(var.resource_names, "virtual_network", "${var.function_app_name}-vnet")
  location            = var.location
  resource_group_name = data.azurerm_resource_group.hosting.name
  address_space       = var.vnet_address_space
}

resource "azurerm_subnet" "integration" {
  name                 = lookup(var.resource_names, "integration_subnet", "function-integration")
  resource_group_name  = data.azurerm_resource_group.hosting.name
  virtual_network_name = azurerm_virtual_network.hosting.name
  address_prefixes     = [var.integration_subnet_prefix]

  delegation {
    name = lookup(var.resource_names, "integration_subnet_delegation", "flex-consumption")
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = lookup(var.resource_names, "private_endpoints_subnet", "private-endpoints")
  resource_group_name  = data.azurerm_resource_group.hosting.name
  virtual_network_name = azurerm_virtual_network.hosting.name
  address_prefixes     = [var.private_endpoints_subnet_prefix]
}

resource "azurerm_private_dns_zone" "storage" {
  for_each            = toset(["blob", "queue", "table"])
  name                = lookup(var.resource_names, "storage_private_dns_zone_${each.key}", "privatelink.${each.key}.core.windows.net")
  resource_group_name = data.azurerm_resource_group.hosting.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each            = azurerm_private_dns_zone.storage
  name                = lookup(var.resource_names, "storage_private_dns_link_${each.key}", "hosting-network")
  private_dns_zone_id = each.value.id
  virtual_network_id  = azurerm_virtual_network.hosting.id
}

resource "azurerm_private_endpoint" "storage" {
  for_each            = azurerm_private_dns_zone.storage
  name                = lookup(var.resource_names, "storage_private_endpoint_${each.key}", "${var.function_app_name}-storage-${each.key}")
  location            = var.location
  resource_group_name = data.azurerm_resource_group.hosting.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = lookup(var.resource_names, "storage_private_service_connection_${each.key}", "storage-${each.key}")
    private_connection_resource_id = data.azurerm_storage_account.hosting.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = lookup(var.resource_names, "storage_private_dns_zone_group_${each.key}", "storage")
    private_dns_zone_ids = [each.value.id]
  }
}

resource "azurerm_storage_container" "application" {
  for_each = {
    "app-package" = lookup(var.resource_names, "deployment_container", "app-package")
    "dr-configs"  = lookup(var.resource_names, "csv_container", "dr-configs")
    "dr-logs"     = lookup(var.resource_names, "log_container", "dr-logs")
  }
  name                  = each.value
  storage_account_id    = data.azurerm_storage_account.hosting.id
  container_access_type = "private"
}

resource "azurerm_log_analytics_workspace" "hosting" {
  name                = lookup(var.resource_names, "log_analytics_workspace", "${var.function_app_name}-logs")
  location            = var.location
  resource_group_name = data.azurerm_resource_group.hosting.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
}

resource "azurerm_application_insights" "hosting" {
  name                         = lookup(var.resource_names, "application_insights", "${var.function_app_name}-insights")
  location                     = var.location
  resource_group_name          = data.azurerm_resource_group.hosting.name
  application_type             = "web"
  workspace_id                 = azurerm_log_analytics_workspace.hosting.id
  local_authentication_enabled = false
}

resource "azurerm_service_plan" "hosting" {
  name                = lookup(var.resource_names, "service_plan", "${var.function_app_name}-plan")
  location            = var.location
  resource_group_name = data.azurerm_resource_group.hosting.name
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "hosting" {
  name                = var.function_app_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.hosting.name
  service_plan_id     = azurerm_service_plan.hosting.id

  storage_container_type                         = "blobContainer"
  storage_container_endpoint                     = "${data.azurerm_storage_account.hosting.primary_blob_endpoint}${azurerm_storage_container.application["app-package"].name}"
  storage_authentication_type                    = "UserAssignedIdentity"
  storage_user_assigned_identity_id              = data.azurerm_user_assigned_identity.source.id
  runtime_name                                   = "powershell"
  runtime_version                                = "7.6"
  instance_memory_in_mb                          = var.instance_memory_in_mb
  maximum_instance_count                         = var.maximum_instance_count
  http_concurrency                               = 1
  virtual_network_subnet_id                      = azurerm_subnet.integration.id
  public_network_access_enabled                  = false
  https_only                                     = true
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.source.id, data.azurerm_user_assigned_identity.target.id]
  }

  site_config {
    minimum_tls_version                    = "1.2"
    scm_minimum_tls_version                = "1.2"
    application_insights_connection_string = azurerm_application_insights.hosting.connection_string
  }

  app_settings = {
    AzureWebJobsStorage__blobServiceUri       = data.azurerm_storage_account.hosting.primary_blob_endpoint
    AzureWebJobsStorage__queueServiceUri      = data.azurerm_storage_account.hosting.primary_queue_endpoint
    AzureWebJobsStorage__tableServiceUri      = data.azurerm_storage_account.hosting.primary_table_endpoint
    AzureWebJobsStorage__credential           = "managedidentity"
    AzureWebJobsStorage__clientId             = data.azurerm_user_assigned_identity.source.client_id
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD;ClientId=${data.azurerm_user_assigned_identity.source.client_id}"
    AZURE_CLIENT_ID                           = data.azurerm_user_assigned_identity.source.client_id
    SOURCE_IDENTITY_CLIENT_ID                 = data.azurerm_user_assigned_identity.source.client_id
    TARGET_IDENTITY_CLIENT_ID                 = data.azurerm_user_assigned_identity.target.client_id
    HOSTING_SUBSCRIPTION_ID                   = var.hosting_subscription_id
    TARGET_SUBSCRIPTION_ID                    = var.dr_subscription_id
    CSV_STORAGE_CONNECTION__blobServiceUri    = data.azurerm_storage_account.hosting.primary_blob_endpoint
    CSV_CONTAINER_NAME                        = azurerm_storage_container.application["dr-configs"].name
    LOG_CONTAINER_NAME                        = azurerm_storage_container.application["dr-logs"].name
    VM_PARALLEL_THROTTLE                      = "1"
    PARALLEL_THROTTLE                         = "1"
    PSWorkerInProcConcurrencyUpperBound       = "1"
    SNAPSHOT_NAME_PREFIX                      = "snap-"
    TARGET_SUBSCRIPTION_SUFFIX                = var.target_name_suffix
    TARGET_RESOURCE_GROUP_SUFFIX              = var.target_name_suffix
    TARGET_VNET_NAME_SUFFIX                   = var.target_name_suffix
    TARGET_VNET_RG_SUFFIX                     = var.target_name_suffix
    TARGET_LB_NAME_SUFFIX                     = var.target_name_suffix
    TARGET_LB_RG_SUFFIX                       = var.target_name_suffix
    TARGET_DES_NAME_SUFFIX                    = var.target_name_suffix
    TARGET_DES_RG_SUFFIX                      = var.target_name_suffix
    TARGET_ASG_NAME_SUFFIX                    = var.target_name_suffix
  }

  depends_on = [azurerm_private_endpoint.storage, azurerm_private_dns_zone_virtual_network_link.storage]
}

resource "azurerm_private_dns_zone" "function" {
  name                = lookup(var.resource_names, "function_private_dns_zone", "privatelink.azurewebsites.net")
  resource_group_name = data.azurerm_resource_group.hosting.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "function" {
  name                = lookup(var.resource_names, "function_private_dns_link", "hosting-network")
  private_dns_zone_id = azurerm_private_dns_zone.function.id
  virtual_network_id  = azurerm_virtual_network.hosting.id
}

resource "azurerm_private_endpoint" "function" {
  name                = lookup(var.resource_names, "function_private_endpoint", "${var.function_app_name}-endpoint")
  location            = var.location
  resource_group_name = data.azurerm_resource_group.hosting.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = lookup(var.resource_names, "function_private_service_connection", "function")
    private_connection_resource_id = azurerm_function_app_flex_consumption.hosting.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = lookup(var.resource_names, "function_private_dns_zone_group", "function")
    private_dns_zone_ids = [azurerm_private_dns_zone.function.id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "function" {
  name                       = lookup(var.resource_names, "function_diagnostic_setting", "${var.function_app_name}-diagnostics")
  target_resource_id         = azurerm_function_app_flex_consumption.hosting.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hosting.id

  enabled_log {
    category = "FunctionAppLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage_services" {
  for_each                   = toset(["blob", "queue", "table"])
  name                       = lookup(var.resource_names, "storage_diagnostic_setting_${each.key}", "${var.function_app_name}-${each.key}-diagnostics")
  target_resource_id         = "${data.azurerm_storage_account.hosting.id}/${each.key}Services/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hosting.id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "Transaction"
  }
}