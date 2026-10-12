mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg"
      location = "italynorth"
    }
  }

  mock_data "azurerm_storage_account" {
    defaults = {
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.Storage/storageAccounts/existingstorageaccount"
      primary_blob_endpoint  = "https://existingstorageaccount.blob.core.windows.net/"
      primary_queue_endpoint = "https://existingstorageaccount.queue.core.windows.net/"
      primary_table_endpoint = "https://existingstorageaccount.table.core.windows.net/"
    }
  }

  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock-identity"
      client_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.Network/virtualNetworks/mock-vnet"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.Network/virtualNetworks/mock-vnet/subnets/mock-subnet"
    }
  }

  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.Network/privateDnsZones/mock.example"
    }
  }

  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.Web/serverfarms/mock-plan"
    }
  }

  mock_resource "azurerm_function_app_flex_consumption" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.Web/sites/mock-function"
      default_hostname = "mock-function.azurewebsites.net"
    }
  }

  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/existing-hosting-rg/providers/Microsoft.OperationalInsights/workspaces/mock-workspace"
    }
  }
}

variables {
  hosting_subscription_id = "00000000-0000-0000-0000-000000000000"
  dr_subscription_id      = "00000000-0000-0000-0000-000000000000"
  resource_group_name     = "existing-hosting-rg"
  storage_account_name    = "existingstorageaccount"
  source_identity_name    = "existing-source-identity"
  target_identity_name    = "existing-target-identity"
  function_app_name       = "func-naming-test"
  resource_names          = {}
}

run "default_names_preserve_compatibility" {
  command = plan

  assert {
    condition = {
      virtual_network                     = azurerm_virtual_network.hosting.name
      integration_subnet                  = azurerm_subnet.integration.name
      integration_subnet_delegation       = azurerm_subnet.integration.delegation[0].name
      private_endpoints_subnet            = azurerm_subnet.private_endpoints.name
      service_plan                        = azurerm_service_plan.hosting.name
      application_insights                = azurerm_application_insights.hosting.name
      log_analytics_workspace             = azurerm_log_analytics_workspace.hosting.name
      function_private_endpoint           = azurerm_private_endpoint.function.name
      function_private_dns_zone           = azurerm_private_dns_zone.function.name
      function_private_dns_link           = azurerm_private_dns_zone_virtual_network_link.function.name
      function_private_service_connection = azurerm_private_endpoint.function.private_service_connection[0].name
      function_private_dns_zone_group     = azurerm_private_endpoint.function.private_dns_zone_group[0].name
      function_diagnostic_setting         = azurerm_monitor_diagnostic_setting.function.name
      } == {
      virtual_network                     = "func-naming-test-vnet"
      integration_subnet                  = "function-integration"
      integration_subnet_delegation       = "flex-consumption"
      private_endpoints_subnet            = "private-endpoints"
      service_plan                        = "func-naming-test-plan"
      application_insights                = "func-naming-test-insights"
      log_analytics_workspace             = "func-naming-test-logs"
      function_private_endpoint           = "func-naming-test-endpoint"
      function_private_dns_zone           = "privatelink.azurewebsites.net"
      function_private_dns_link           = "hosting-network"
      function_private_service_connection = "function"
      function_private_dns_zone_group     = "function"
      function_diagnostic_setting         = "func-naming-test-diagnostics"
    }
    error_message = "Omitting resource_names must preserve all existing Function/network/monitoring names."
  }

  assert {
    condition = alltrue([
      for service in ["blob", "queue", "table"] :
      azurerm_private_dns_zone.storage[service].name == "privatelink.${service}.core.windows.net" &&
      azurerm_private_dns_zone_virtual_network_link.storage[service].name == "hosting-network" &&
      azurerm_private_endpoint.storage[service].name == "func-naming-test-storage-${service}" &&
      azurerm_private_endpoint.storage[service].private_service_connection[0].name == "storage-${service}" &&
      azurerm_private_endpoint.storage[service].private_dns_zone_group[0].name == "storage" &&
      azurerm_monitor_diagnostic_setting.storage_services[service].name == "func-naming-test-${service}-diagnostics"
    ])
    error_message = "Default storage resource and child-resource names must stay unchanged."
  }

  assert {
    condition = alltrue([
      for name in ["app-package", "dr-configs", "dr-logs"] : azurerm_storage_container.application[name].name == name
    ]) && azurerm_function_app_flex_consumption.hosting.app_settings["CSV_CONTAINER_NAME"] == "dr-configs" && azurerm_function_app_flex_consumption.hosting.app_settings["LOG_CONTAINER_NAME"] == "dr-logs"
    error_message = "Default container names and application settings must stay unchanged."
  }
}

run "customer_names_reach_every_resource" {
  command = plan

  variables {
    resource_names = {
      virtual_network                          = "vnet-client-host"
      integration_subnet                       = "snet-client-functions"
      integration_subnet_delegation            = "delegation-client-functions"
      private_endpoints_subnet                 = "snet-client-endpoints"
      service_plan                             = "asp-client-functions"
      application_insights                     = "appi-client-functions"
      log_analytics_workspace                  = "log-client-functions"
      deployment_container                     = "client-packages"
      csv_container                            = "client-configs"
      log_container                            = "client-logs"
      function_private_endpoint                = "pep-client-function"
      function_private_dns_zone                = "privatelink.azurewebsites.net"
      function_private_dns_link                = "link-client-function"
      function_private_service_connection      = "connection-client-function"
      function_private_dns_zone_group          = "group-client-function"
      function_diagnostic_setting              = "diagnostics-client-function"
      storage_private_endpoint_blob            = "pep-client-blob"
      storage_private_endpoint_queue           = "pep-client-queue"
      storage_private_endpoint_table           = "pep-client-table"
      storage_private_dns_zone_blob            = "privatelink.blob.core.windows.net"
      storage_private_dns_zone_queue           = "privatelink.queue.core.windows.net"
      storage_private_dns_zone_table           = "privatelink.table.core.windows.net"
      storage_private_dns_link_blob            = "link-client-blob"
      storage_private_dns_link_queue           = "link-client-queue"
      storage_private_dns_link_table           = "link-client-table"
      storage_private_service_connection_blob  = "connection-client-blob"
      storage_private_service_connection_queue = "connection-client-queue"
      storage_private_service_connection_table = "connection-client-table"
      storage_private_dns_zone_group_blob      = "group-client-blob"
      storage_private_dns_zone_group_queue     = "group-client-queue"
      storage_private_dns_zone_group_table     = "group-client-table"
      storage_diagnostic_setting_blob          = "diagnostics-client-blob"
      storage_diagnostic_setting_queue         = "diagnostics-client-queue"
      storage_diagnostic_setting_table         = "diagnostics-client-table"
    }
  }

  assert {
    condition = alltrue([
      azurerm_virtual_network.hosting.name == var.resource_names["virtual_network"],
      azurerm_subnet.integration.name == var.resource_names["integration_subnet"],
      azurerm_subnet.integration.delegation[0].name == var.resource_names["integration_subnet_delegation"],
      azurerm_subnet.private_endpoints.name == var.resource_names["private_endpoints_subnet"],
      azurerm_service_plan.hosting.name == var.resource_names["service_plan"],
      azurerm_application_insights.hosting.name == var.resource_names["application_insights"],
      azurerm_log_analytics_workspace.hosting.name == var.resource_names["log_analytics_workspace"],
      azurerm_private_endpoint.function.name == var.resource_names["function_private_endpoint"],
      azurerm_private_dns_zone.function.name == var.resource_names["function_private_dns_zone"],
      azurerm_private_dns_zone_virtual_network_link.function.name == var.resource_names["function_private_dns_link"],
      azurerm_private_endpoint.function.private_service_connection[0].name == var.resource_names["function_private_service_connection"],
      azurerm_private_endpoint.function.private_dns_zone_group[0].name == var.resource_names["function_private_dns_zone_group"],
      azurerm_monitor_diagnostic_setting.function.name == var.resource_names["function_diagnostic_setting"]
    ])
    error_message = "Customer overrides must reach every Function/network/monitoring resource name."
  }

  assert {
    condition = alltrue([
      for service in ["blob", "queue", "table"] :
      azurerm_private_dns_zone.storage[service].name == var.resource_names["storage_private_dns_zone_${service}"] &&
      azurerm_private_dns_zone_virtual_network_link.storage[service].name == var.resource_names["storage_private_dns_link_${service}"] &&
      azurerm_private_endpoint.storage[service].name == var.resource_names["storage_private_endpoint_${service}"] &&
      azurerm_private_endpoint.storage[service].private_service_connection[0].name == var.resource_names["storage_private_service_connection_${service}"] &&
      azurerm_private_endpoint.storage[service].private_dns_zone_group[0].name == var.resource_names["storage_private_dns_zone_group_${service}"] &&
      azurerm_monitor_diagnostic_setting.storage_services[service].name == var.resource_names["storage_diagnostic_setting_${service}"]
    ])
    error_message = "Customer overrides must reach all storage resource and child-resource names."
  }

  assert {
    condition = (azurerm_storage_container.application["app-package"].name == "client-packages" &&
      azurerm_storage_container.application["dr-configs"].name == "client-configs" &&
      azurerm_storage_container.application["dr-logs"].name == "client-logs" &&
      azurerm_function_app_flex_consumption.hosting.storage_container_endpoint == "https://existingstorageaccount.blob.core.windows.net/client-packages" &&
      azurerm_function_app_flex_consumption.hosting.app_settings["CSV_CONTAINER_NAME"] == "client-configs" &&
      azurerm_function_app_flex_consumption.hosting.app_settings["LOG_CONTAINER_NAME"] == "client-logs" &&
    output.deployment_container_name == "client-packages" && output.csv_container_name == "client-configs" && output.log_container_name == "client-logs")
    error_message = "Renamed containers must propagate to deployment, runtime settings and operator outputs."
  }
}

run "partial_override_preserves_other_defaults" {
  command = plan

  variables {
    resource_names = { csv_container = "client-configs" }
  }

  assert {
    condition = (azurerm_virtual_network.hosting.name == "func-naming-test-vnet" &&
      azurerm_service_plan.hosting.name == "func-naming-test-plan" &&
      azurerm_storage_container.application["app-package"].name == "app-package" &&
      azurerm_storage_container.application["dr-logs"].name == "dr-logs" &&
      azurerm_function_app_flex_consumption.hosting.app_settings["CSV_CONTAINER_NAME"] == "client-configs" &&
    azurerm_function_app_flex_consumption.hosting.app_settings["LOG_CONTAINER_NAME"] == "dr-logs")
    error_message = "A partial naming override must leave unrelated defaults unchanged."
  }
}

run "unknown_naming_key_is_rejected" {
  command = plan
  variables {
    resource_names = { virtual_netwrok = "misspelled-key" }
  }
  expect_failures = [var.resource_names]
}

run "empty_name_is_rejected" {
  command = plan
  variables {
    resource_names = { service_plan = "" }
  }
  expect_failures = [var.resource_names]
}

run "null_name_is_rejected" {
  command = plan
  variables {
    resource_names = { service_plan = null }
  }
  expect_failures = [var.resource_names]
}

run "whitespace_name_is_rejected" {
  command = plan
  variables {
    resource_names = { service_plan = " client-plan " }
  }
  expect_failures = [var.resource_names]
}

run "invalid_container_name_is_rejected" {
  command = plan
  variables {
    resource_names = { csv_container = "Invalid_Container" }
  }
  expect_failures = [var.resource_names]
}

run "duplicate_container_names_are_rejected" {
  command = plan
  variables {
    resource_names = { csv_container = "app-package" }
  }
  expect_failures = [var.resource_names]
}

run "incompatible_private_dns_zone_is_rejected" {
  command = plan
  variables {
    resource_names = { function_private_dns_zone = "client.example" }
  }
  expect_failures = [var.resource_names]
}