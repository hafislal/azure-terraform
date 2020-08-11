##############################
## Azure App Service - Main ##
##############################
#define resource group
resource "azurerm_resource_group" "appservice-rg" {
  name     = "${var.division}-${var.region}-${var.environment}-${var.app_name}-RG"
  location = var.location

  tags = {
    description = var.description
    environment = var.environment
    owner       = var.owner  
  }
}
#Configure VNet and Subnet

#Congigure keyvault

data "azurerm_client_config" "current" {}

resource "random_id" "server" {
  keepers = {
    ami_id = 1
  }
    byte_length = 8
}

resource "azurerm_key_vault" "keyvault" {
  name                = format("%s%s", "kv", random_id.server.hex)
  location            = azurerm_resource_group.appservice-rg.location
  resource_group_name = azurerm_resource_group.appservice-rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name = "premium"

  }
  resource "azurerm_key_vault_secret" "db-pass" {
  name         = "db-host"
  value        = random_password.db-password.result
  key_vault_id = azurerm_key_vault.keyvault.id

}

#Create storage account

resource "azurerm_storage_account" "strg-account" {
  name                     = lower("${var.division}${var.region}${var.environment}${var.app_name}strg")
  resource_group_name      = azurerm_resource_group.appservice-rg.name
  location                 = azurerm_resource_group.appservice-rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
#Creat shared folder
resource "azurerm_storage_share" "share-folder" {
  name                 = lower("${var.app_name}-share")
  storage_account_name = azurerm_storage_account.strg-account.name
  quota                = 50
}
#Create random password for mysql

resource "random_password" "db-password" {
  length = 16
  special = true
  override_special = "_%@"
}

# Create a MySQL Server

  resource "azurerm_mysql_server" "mysql-server" {
  name 			= lower("${var.division}-${var.region}-${var.environment}-${var.app_name}-db")
  location 		= azurerm_resource_group.appservice-rg.location 
  resource_group_name 	= azurerm_resource_group.appservice-rg.name 
 
  administrator_login          = lower("${var.app_name}${var.environment}-db-user")
  administrator_login_password = random_password.db-password.result
 
  sku_name = var.mysql-sku-name
  version  = var.mysql-version
 
  storage_mb        = var.mysql-storage
  auto_grow_enabled = true
  
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  public_network_access_enabled     = true
  ssl_enforcement_enabled           = true
  ssl_minimal_tls_version_enforced  = "TLS1_2"
}

# Create a MySQL Database
resource "azurerm_mysql_database" "mysql-db" {
  name                	=  lower("${var.app_name}${var.environment}-db")
  resource_group_name   =  azurerm_resource_group.appservice-rg.name
  server_name         	=  azurerm_mysql_server.mysql-server.name
  charset             	= "utf8"
  collation           	= "utf8_unicode_ci"
}

# Create the App Service Plan
resource "azurerm_app_service_plan" "service-plan" {
  name                = "${var.division}-${var.region}-${var.environment}-${var.app_name}-SP"
  location            = azurerm_resource_group.appservice-rg.location
  resource_group_name = azurerm_resource_group.appservice-rg.name
  kind                = "Linux"
  reserved            = true

  sku {
    tier = "Premium"
    size = "S2"
  }
}

# Create the App Service
resource "azurerm_app_service" "app-service" {
  name                = "${var.division}-${var.region}-${var.environment}-${var.app_name}-APP"
  location            = azurerm_resource_group.appservice-rg.location
  resource_group_name = azurerm_resource_group.appservice-rg.name
  app_service_plan_id = azurerm_app_service_plan.service-plan.id

  site_config {
    php_version = "7.3"
  }
    
  identity {
    type = "SystemAssigned"
  }
  #pass DB parameters to AppService
  app_settings = {
    "DBHost" =  azurerm_mysql_server.mysql-server.fqdn
    "DBName" =  azurerm_mysql_database.mysql-db.name
    "DBUser" =  lower("${var.app_name}${var.environment}-db-user")
    "DBPass" =  "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.keyvault.vault_uri}secrets/${azurerm_key_vault_secret.db-pass.name}/${azurerm_key_vault_secret.db-pass.version})"
  }
  storage_account {
    name              = lower("${var.app_name}-mount")
    type              = "AzureFiles"
    account_name      = azurerm_storage_account.strg-account.name
    share_name        = azurerm_storage_share.share-folder.name
    access_key        = azurerm_storage_account.strg-account.primary_access_key
    mount_path        = "/home/site/wwwroot/static/"
  
}
#allow pipe line to access  key vault
}
resource "azurerm_key_vault_access_policy" "policy1" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = data.azurerm_client_config.current.object_id

   key_permissions = [
      "create",
      "get",
    ]

   secret_permissions = [
      "set",
      "get",
      "delete",
    ]
}
#allow app service to access  key vault
resource "azurerm_key_vault_access_policy" "policy2" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = azurerm_app_service.app-service.identity.0.principal_id

   key_permissions = [
      "create",
      "get",
    ]

   secret_permissions = [
      "set",
      "get",
      "delete",
    ]
}
