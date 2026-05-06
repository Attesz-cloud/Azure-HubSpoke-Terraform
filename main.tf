terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "network_rg" {
  name     = "rg-hubspoke-uz"
  location = "West Europe"
}

# Hub Virtual Network
resource "azurerm_virtual_network" "hub_vnet" {
  name                = "vnet-hub"
  location            = azurerm_resource_group.network_rg.location
  resource_group_name = azurerm_resource_group.network_rg.name
  address_space       = ["10.0.0.0/16"]
}

# Subnet for shared services
resource "azurerm_subnet" "hub_mgmt_subnet" {
  name                 = "snet-hub-mgmt"
  resource_group_name  = azurerm_resource_group.network_rg.name
  virtual_network_name = azurerm_virtual_network.hub_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}


# Spoke Virtual Network
resource "azurerm_virtual_network" "spoke_vnet" {
  name                = "vnet-spoke"
  location            = azurerm_resource_group.network_rg.location
  resource_group_name  = azurerm_resource_group.network_rg.name
  address_space       = ["10.1.0.0/16"]
}

# Subnet in Spoke for workflows (Workload)
resource "azurerm_subnet" "spoke_workload_subnet" {
  name                 = "snet-spoke-workload"
  resource_group_name  = azurerm_resource_group.network_rg.name
  virtual_network_name = azurerm_virtual_network.spoke_vnet.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_subnet" "fw_subnet" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = "rg-hubspoke-uz"
  virtual_network_name = "vnet-hub"
  address_prefixes     = ["10.0.100.0/26"]
}

resource "azurerm_public_ip" "fw_pip" {
  name                = "pip-firewall"
  location            = "westeurope"
  resource_group_name  = "rg-hubspoke-uz"
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_firewall" "hub_fw" {
  name                = "fw-central"
  location            = "westeurope"
  resource_group_name  = "rg-hubspoke-uz"
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.fw_subnet.id
    public_ip_address_id = azurerm_public_ip.fw_pip.id
   }
firewall_policy_id = azurerm_firewall_policy.fw_pol.id
}


# 1. Peering from Hub to Spoke
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "hub-to-spoke"
  resource_group_name          = "rg-hubspoke-uz"
  virtual_network_name         = "vnet-hub"
  remote_virtual_network_id    = azurerm_virtual_network.spoke_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# 2. Peering from Spoke to Hub
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "spoke-to-hub"
  resource_group_name          = "rg-hubspoke-uz"
  virtual_network_name         = "vnet-spoke" 
  remote_virtual_network_id    = azurerm_virtual_network.hub_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# Creating the route table
resource "azurerm_route_table" "spoke_rt" {
  name                = "rt-spoke-to-hub"
  location            = "westeurope"
  resource_group_name  = "rg-hubspoke-uz"
}

# The forced route (All traffic -> Firewall)
resource "azurerm_route" "default_route" {
  name                = "outbound-to-fw"
  resource_group_name  = "rg-hubspoke-uz"
  route_table_name    = azurerm_route_table.spoke_rt.name
  address_prefix      = "0.0.0.0/0"
  next_hop_type       = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.hub_fw.ip_configuration[0].private_ip_address
}

# Connecting to the Spoke subnet
resource "azurerm_subnet_route_table_association" "spoke_assoc" {
  subnet_id      = azurerm_subnet.spoke_workload_subnet.id
  route_table_id = azurerm_route_table.spoke_rt.id
}


# Network card for the VM
resource "azurerm_network_interface" "vm_nic" {
  name                = "nic-spoke-vm"
  location            = "westeurope"
  resource_group_name  = "rg-hubspoke-uz"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.spoke_workload_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# The Virtual Machine itself (Linux - cheaper and faster)
resource "azurerm_linux_virtual_machine" "spoke_vm" {
  name                = "vm-spoke-test"
  resource_group_name  = "rg-hubspoke-uz"
  location            = "westeurope"
  size                = "Standard_D2s_v3" # mid-range, as Standard_B1s, Standard_B2s were not available
  admin_username      = "adminuser"
  network_interface_ids = [azurerm_network_interface.vm_nic.id]

  admin_password                  = "passP@ssw0rd1234!" # a key vault is required in acute cases!
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }


  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }
}

# Creating the Policy
resource "azurerm_firewall_policy" "fw_pol" {
  name                = "fw-policy-spoke"
  resource_group_name  = "rg-hubspoke-uz"
  location            = "westeurope"
  sku                 = "Standard"
}


# The specific rules (Google permission)
resource "azurerm_firewall_policy_rule_collection_group" "spoke_rules" {
  name               = "spoke-traffic-rules"
  firewall_policy_id = azurerm_firewall_policy.fw_pol.id
  priority           = 100

  application_rule_collection {
    name     = "allow-google"
    priority = 110
    action   = "Allow"
    rule {
      name = "google-access"
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
      source_addresses  = ["10.1.1.0/24"] # My Spoke subnet
      destination_fqdns = ["*.google.com", "google.com"]
    }
  }
}



resource "random_string" "storage_name" {
  length  = 6
  special = false
  upper   = false
}

# Storage Account itself
resource "azurerm_storage_account" "secure_storage" {
  name                     = "attila19791117"
  resource_group_name      = "rg-hubspoke-uz"
  location                 = "westeurope"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Private Endpoint corrected, DNA-enhanced version
resource "azurerm_private_endpoint" "storage_pe" {
  name                = "pe-storage"
  location            = "westeurope"
  resource_group_name  = "rg-hubspoke-uz"
  subnet_id           = azurerm_subnet.spoke_workload_subnet.id

  private_service_connection {
    name                           = "storage-conn"
    private_connection_resource_id = azurerm_storage_account.secure_storage.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  # I think this part ensures that the VM gets the internal IP for the name
  private_dns_zone_group {
    name                 = "storage-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_dns.id]
  }
}

# Private DNS Zone for Storage
resource "azurerm_private_dns_zone" "storage_dns" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = "rg-hubspoke-uz"
}

# Connecting DNS to the Spoke network
resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "storage-dns-link"
  resource_group_name   = "rg-hubspoke-uz"
  private_dns_zone_name = azurerm_private_dns_zone.storage_dns.name
  virtual_network_id    = azurerm_virtual_network.spoke_vnet.id
}