variable "hosting_subscription_id" {
  type        = string
  description = "Azure subscription that contains the existing hosting Resource Group."
}

variable "resource_group_name" {
  type        = string
  description = "Existing Resource Group in which the new hosting resources will be created."
}

variable "location" {
  type        = string
  description = "Region for the Function App, its network and monitoring resources."
  default     = "italynorth"
}

variable "storage_account_name" {
  type        = string
  description = "Existing StorageV2 account for host storage, deployment packages, CSVs and logs."
}

variable "storage_resource_group_name" {
  type        = string
  description = "Existing storage account Resource Group; null uses resource_group_name."
  default     = null
  nullable    = true
}

variable "source_identity_name" {
  type        = string
  description = "Existing user-assigned identity with storage access and primary resource read permissions."
}

variable "source_identity_resource_group_name" {
  type        = string
  description = "Source/storage identity Resource Group; null uses resource_group_name."
  default     = null
  nullable    = true
}

variable "target_identity_name" {
  type        = string
  description = "Existing user-assigned identity with the permissions needed for DR resource creation."
}

variable "target_identity_resource_group_name" {
  type        = string
  description = "DR identity Resource Group; null uses resource_group_name."
  default     = null
  nullable    = true
}

variable "function_app_name" {
  type        = string
  description = "Globally unique Function App name; prefixes default resource names unless overridden in resource_names."

  validation {
    condition     = length(var.function_app_name) <= 32 && can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.function_app_name))
    error_message = "Use 2-32 lower-case letters, digits or hyphens; start with a letter and end with a letter or digit."
  }
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Address space for the new hosting VNet; choose prefixes that do not overlap existing networks."
  default     = ["10.80.0.0/24"]
}

variable "integration_subnet_prefix" {
  type        = string
  description = "Dedicated Flex integration subnet; /27 or larger is required for this single-app configuration."
  default     = "10.80.0.0/27"

  validation {
    condition     = can(cidrhost(var.integration_subnet_prefix, 0)) && try(tonumber(split("/", var.integration_subnet_prefix)[1]) <= 27, false)
    error_message = "Provide a valid IPv4 subnet with prefix length no greater than 27."
  }
}

variable "private_endpoints_subnet_prefix" {
  type        = string
  description = "Separate subnet for the Function and three storage private endpoints."
  default     = "10.80.0.32/27"
}

variable "target_name_suffix" {
  type        = string
  description = "Nonempty suffix used to resolve existing DR Resource Groups, VNet, DES, ASGs and Load Balancers."
  default     = "-DR"

  validation {
    condition     = length(trimspace(var.target_name_suffix)) > 0 && var.target_name_suffix == trimspace(var.target_name_suffix)
    error_message = "Provide a nonempty DR naming suffix without leading or trailing whitespace."
  }
}

variable "target_subscription_suffix" {
  type        = string
  description = "Nonempty suffix used to resolve each source subscription's DR subscription independently of resource naming."
  default     = "-DR"

  validation {
    condition     = length(trimspace(var.target_subscription_suffix)) > 0 && var.target_subscription_suffix == trimspace(var.target_subscription_suffix)
    error_message = "Provide a nonempty DR subscription suffix without leading or trailing whitespace."
  }
}

variable "maximum_instance_count" {
  type        = number
  description = "Upper limit for on-demand Function instances."
  default     = 10

  validation {
    condition     = var.maximum_instance_count >= 1 && var.maximum_instance_count <= 1000 && floor(var.maximum_instance_count) == var.maximum_instance_count
    error_message = "Set an integer between 1 and 1000."
  }
}

variable "instance_memory_in_mb" {
  type        = number
  description = "Memory per Function instance. Start with 2048 MB and change only after testing."
  default     = 2048

  validation {
    condition     = contains([512, 2048, 4096], var.instance_memory_in_mb)
    error_message = "Select 512, 2048 or 4096 MB."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Log Analytics retention period in days."
  default     = 30
}

variable "resource_names" {
  type        = map(string)
  description = "Customer-specific resource and child-resource names. Omitted keys preserve existing defaults; private DNS zone names must retain Azure public-cloud service names."
  default     = {}
  nullable    = false

  validation {
    condition = length(setsubtract(toset(keys(var.resource_names)), toset([
      "virtual_network",
      "integration_subnet",
      "integration_subnet_delegation",
      "private_endpoints_subnet",
      "service_plan",
      "log_analytics_workspace",
      "application_insights",
      "deployment_container",
      "csv_container",
      "log_container",
      "function_private_endpoint",
      "function_private_dns_zone",
      "function_private_dns_link",
      "function_private_service_connection",
      "function_private_dns_zone_group",
      "function_diagnostic_setting",
      "storage_private_endpoint_blob",
      "storage_private_endpoint_queue",
      "storage_private_endpoint_table",
      "storage_private_dns_zone_blob",
      "storage_private_dns_zone_queue",
      "storage_private_dns_zone_table",
      "storage_private_dns_link_blob",
      "storage_private_dns_link_queue",
      "storage_private_dns_link_table",
      "storage_private_service_connection_blob",
      "storage_private_service_connection_queue",
      "storage_private_service_connection_table",
      "storage_private_dns_zone_group_blob",
      "storage_private_dns_zone_group_queue",
      "storage_private_dns_zone_group_table",
      "storage_diagnostic_setting_blob",
      "storage_diagnostic_setting_queue",
      "storage_diagnostic_setting_table"
    ]))) == 0
    error_message = "resource_names contains an unsupported key. Use the keys documented in terraform.tfvars.example."
  }

  validation {
    condition = alltrue([
      for name in values(var.resource_names) :
      name == null ? false : length(trimspace(name)) > 0 && name == trimspace(name)
    ])
    error_message = "Resource names must be nonempty, nonnull and have no leading or trailing whitespace."
  }

  validation {
    condition = alltrue([
      for key, fallback in { deployment_container = "app-package", csv_container = "dr-configs", log_container = "dr-logs" } :
      try(length(lookup(var.resource_names, key, fallback)) >= 3 && length(lookup(var.resource_names, key, fallback)) <= 63 &&
        can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", lookup(var.resource_names, key, fallback))) &&
      !strcontains(lookup(var.resource_names, key, fallback), "--"), false)
    ])
    error_message = "Container names must have 3-63 lowercase letters, digits or hyphens, start/end alphanumeric and contain no consecutive hyphens."
  }

  validation {
    condition = length(toset([
      lookup(var.resource_names, "deployment_container", "app-package"),
      lookup(var.resource_names, "csv_container", "dr-configs"),
      lookup(var.resource_names, "log_container", "dr-logs")
    ])) == 3
    error_message = "Deployment, CSV and log containers must have distinct names."
  }

  validation {
    condition = lookup(var.resource_names, "function_private_dns_zone", "privatelink.azurewebsites.net") == "privatelink.azurewebsites.net" && alltrue([
      for service in ["blob", "queue", "table"] :
      lookup(var.resource_names, "storage_private_dns_zone_${service}", "privatelink.${service}.core.windows.net") == "privatelink.${service}.core.windows.net"
    ])
    error_message = "Private DNS zones must retain the Azure public-cloud names privatelink.azurewebsites.net and privatelink.<blob|queue|table>.core.windows.net. Customize endpoint/link/group names instead."
  }
}