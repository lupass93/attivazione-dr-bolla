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

variable "dr_subscription_id" {
  type        = string
  description = "Destination subscription ID. Primary subscription IDs or names are supplied in the CSV."
}

variable "function_app_name" {
  type        = string
  description = "Globally unique Function App name; also prefixes the new network and monitoring resources."

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
  description = "Suffix used to resolve existing DR Resource Groups, VNet, DES, ASGs and Load Balancers."
  default     = "-DR"
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