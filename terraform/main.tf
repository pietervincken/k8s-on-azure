# We strongly recommend using the required_providers block to set the
# Azure Provider source and version being used
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.68.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "2.41.0"
    }
  }
  backend "azurerm" {}
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
}

# Configure the Azure Active Directory Provider
provider "azuread" {
}

locals {

  email       = "pieter.vincken@ordina.be"
  name        = "renovate-talk"
  base_domain = "pietervincken.com"

  common_tags = {
    created-by = local.email
    project    = local.name
  }

  location = "West Europe"
  rg       = "rg-${local.name}"

  tenant_domain = data.azuread_domains.aad_domains.domains.0.domain_name
  upn           = "${replace(local.email, "@", "_")}#EXT#@${local.tenant_domain}"
}

data "azurerm_subscription" "current" {
}

resource "azurerm_resource_group" "rg" {
  name     = local.rg
  location = local.location
}

resource "azurerm_container_registry" "acr" {
  name                = replace("${local.name}-acr", "-", "")
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

resource "azurerm_role_assignment" "k8s_to_acr" {
  principal_id                     = azurerm_kubernetes_cluster.cluster.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "user_to_acr" {
  principal_id         = data.azuread_user.user.object_id
  role_definition_name = "AcrPush"
  scope                = azurerm_container_registry.acr.id
}

resource "azurerm_kubernetes_cluster" "cluster" {
  name                = "${local.name}-k8s"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = local.name
  kubernetes_version  = "1.28.3"

  default_node_pool {
    zones               = [3]
    enable_auto_scaling = false
    vm_size             = "standard_b2ms"
    name                = "default"
    os_sku              = "Ubuntu" # TODO explorer AzureLinux

    node_count = 3

    temporary_name_for_rotation = "tempdefault"
  }

  azure_active_directory_role_based_access_control {
    managed = true
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

## TODO add correct labels and tolerations to workloads!
# resource "azurerm_kubernetes_cluster_node_pool" "spot" {
#   name                  = "spot"
#   kubernetes_cluster_id = azurerm_kubernetes_cluster.cluster.id
#   vm_size               = "Standard_DS2_v2"
#   enable_auto_scaling   = true

#   min_count  = 1
#   max_count  = 10
#   node_count = 1

#   spot_max_price = -1

#   priority        = "Spot"
#   eviction_policy = "Delete"

#   lifecycle {
#     ignore_changes = [node_count]
#   }

#   tags = local.common_tags
# }

data "azuread_user" "user" {
  user_principal_name = local.upn
}

data "azuread_domains" "aad_domains" {

}

## Id is needed for scope of role assignment.
data "azurerm_resource_group" "k8s_node_rg" {
  name = azurerm_kubernetes_cluster.cluster.node_resource_group
}

# Needed for aad-pod-identity
# Contributor role on VMSS
resource "azurerm_role_assignment" "aad_pod_identity_VMC" {
  scope                = data.azurerm_resource_group.k8s_node_rg.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_kubernetes_cluster.cluster.kubelet_identity[0].object_id
}

# Needed for aad-pod-identity
# Managed Identity Operator role on resource group holding the actual identities
resource "azurerm_role_assignment" "aad_pod_identity_MIO" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.cluster.kubelet_identity[0].object_id
}

# Demo users access (local.email)
resource "azurerm_role_assignment" "admin_access" {
  scope                = azurerm_kubernetes_cluster.cluster.id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = data.azuread_user.user.object_id
}

resource "azurerm_key_vault" "keyvault" {
  name                = "kv${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "standard"
  tenant_id           = data.azurerm_subscription.current.tenant_id
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_key_vault_secret" "acr_username" {
  name         = "acr-username"
  value        = azurerm_container_registry.acr.admin_username
  key_vault_id = azurerm_key_vault.keyvault.id

  depends_on = [azurerm_key_vault_access_policy.admin_access]
}

resource "azurerm_key_vault_secret" "acr_password" {
  name         = "acr-password"
  value        = azurerm_container_registry.acr.admin_password
  key_vault_id = azurerm_key_vault.keyvault.id
  depends_on   = [azurerm_key_vault_access_policy.admin_access]
}

# Access for user to keyvault
resource "azurerm_key_vault_access_policy" "admin_access" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id    = azurerm_key_vault.keyvault.tenant_id
  object_id    = data.azuread_user.user.object_id

  secret_permissions = [
    "Backup", "Delete", "Get", "List", "Purge", "Recover", "Restore", "Set"
  ]
}

resource "azurerm_user_assigned_identity" "external_secrets_operator" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "external-secrets-operator"
}



resource "azurerm_key_vault_access_policy" "external_secrets_operator" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id    = azurerm_key_vault.keyvault.tenant_id
  object_id    = azurerm_user_assigned_identity.external_secrets_operator.principal_id

  secret_permissions = [
    "Get", "List"
  ]

  key_permissions = [
    "Decrypt", "Encrypt", "Get", "List", "UnwrapKey", "Verify", "WrapKey"
  ]

  certificate_permissions = [
    "Get", "List"
  ]

}

# DNS Zone for this project
resource "azurerm_dns_zone" "domain" {
  name                = "${local.name}.${local.base_domain}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_user_assigned_identity" "external_dns_operator" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "external-dns-operator"
}

# External DNS operator permissions on dns zone
resource "azurerm_role_assignment" "external_dns_operator" {
  scope                = azurerm_dns_zone.domain.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns_operator.principal_id
}

# Kaniko build (required for ACR push)
resource "azurerm_user_assigned_identity" "kaniko" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "kaniko"
}

resource "azurerm_role_assignment" "kaniko_to_acr" {
  principal_id         = azurerm_user_assigned_identity.kaniko.principal_id
  role_definition_name = "AcrPush"
  scope                = azurerm_container_registry.acr.id
}

resource "azurerm_storage_account" "thanos" {
  name                     = replace("${local.name}-thanos", "-", "")
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
}

resource "azurerm_user_assigned_identity" "thanos" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "thanos"
}

resource "azurerm_role_assignment" "thanos_to_storage_account" {
  principal_id         = azurerm_user_assigned_identity.thanos.principal_id
  role_definition_name = "Storage Account Contributor"
  scope                = azurerm_storage_account.thanos.id
}
