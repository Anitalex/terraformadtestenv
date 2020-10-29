# Configure the Azure Provider
provider "azurerm" {
  # whilst the `version` attribute is optional, we recommend pinning to a given version of the Provider
  version = "=2.20.0"
  features {}
}

# Create a resource group
resource "azurerm_resource_group" "testEnv" {
  name     = "rg-testEnv"
  location = "East US"
}

# Virtual network 10.0.0.0/16
resource "azurerm_virtual_network" "network" {
  name = "virtual-network"
  address_space = ["10.0.0.0/16"]
  location = azurerm_resource_group.testEnv.location
  resource_group_name = azurerm_resource_group.testEnv.name
}

# Subnet 10.0.0.0/24
resource "azurerm_subnet" "internal" {
  name = "subnet"
  resource_group_name = azurerm_resource_group.testEnv.name
  virtual_network_name = azurerm_virtual_network.network.name
  address_prefixes = ["10.0.0.0/24"]
}

# Create 1 public IP for DC
resource "azurerm_public_ip" "domain_controller" {
  name                    = "DC-public-ip"
  location                = azurerm_resource_group.testEnv.location
  resource_group_name     = azurerm_resource_group.testEnv.name
  allocation_method       = "Static"
}

# Network interface for DC
resource "azurerm_network_interface" "dc_nic" {
  name = "dc-nic"
  location = azurerm_resource_group.testEnv.location
  resource_group_name = azurerm_resource_group.testEnv.name

  ip_configuration {
    name = "static"
    subnet_id = azurerm_subnet.internal.id
    private_ip_address_allocation = "Static"
    private_ip_address = cidrhost("10.0.0.0/24", 5)
    public_ip_address_id = azurerm_public_ip.domain_controller.id
  }
}

# Dynamically retrieve our public outgoing IP
data "http" "outgoing_ip" {
  url = "http://ipv4.icanhazip.com"
}
locals {
  outgoing_ip = chomp(data.http.outgoing_ip.body)
}

# Network Security Group
resource "azurerm_network_security_group" "dc_nsg" {
  name = "dc-nsg"
  location = azurerm_resource_group.testEnv.location
  resource_group_name = azurerm_resource_group.testEnv.name

  # RDP
  security_rule {
    name                       = "Allow-RDP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "${local.outgoing_ip}/32"
    destination_address_prefix = "*"
  }

  # WinRM
  security_rule {
    name                       = "Allow-WinRM"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5985"
    source_address_prefix      = "${local.outgoing_ip}/32"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "domain_controller" {
  network_interface_id = azurerm_network_interface.dc_nic.id
  network_security_group_id = azurerm_network_security_group.dc_nsg.id
}

# Generate a Random password for our domain controller
resource "random_password" "domain_controller_password" {
  length = 16
}

# VM for our domain controller
resource "azurerm_virtual_machine" "domain_controller" {
  name                  = "domain-controller"
  location              = azurerm_resource_group.testEnv.location
  resource_group_name   = azurerm_resource_group.testEnv.name
  network_interface_ids = [azurerm_network_interface.dc_nic.id]
  # List of available sizes: https://docs.microsoft.com/en-us/azure/cloud-services/cloud-services-sizes-specs
  vm_size               = "Standard_D1_v2"
  # Base image
  storage_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }
  
  # Disk
  delete_os_disk_on_termination = true
  storage_os_disk {
    name              = "domain-controller-os-disk"
    create_option     = "FromImage"
  }
  os_profile {
    computer_name  = "DC-1"
    # Note: you can't use admin or Administrator in here, Azure won't allow you to do so :-)
    admin_username = "carlos"
    admin_password = random_password.domain_controller_password.result
  }
  os_profile_windows_config {
    # Enable WinRM - we'll need to later
    winrm {
      protocol = "HTTP"
    }
  }
  tags = {
    kind = "domain_controller"
  }
}

# output the password
output "domain_controller_password" {
  value = random_password.domain_controller_password.result
}

# output the public IP
output "domain_controller_public_ip" {
  value = azurerm_public_ip.domain_controller.ip_address
}

