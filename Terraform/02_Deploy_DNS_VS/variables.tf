### --------- AVI CONTROLLER VARIABLES ---------

# REPLACE WITH YOUR OWN VALUES
# Avi Controller Cluster/Controller IP
variable "avi_controller_ip" {
  default = "10.15.11.30"  
}

# REPLACE WITH YOUR OWN VALUES
# Avi Username (i.e., "admin"; If you want to input user, use default = "")
variable "avi_username" {
  default = "admin" 
}

# REPLACE WITH YOUR OWN VALUES
# Avi Password (If you want to input password, use default = "")
variable "avi_password" {
  default = "VMware1!"  
}

# REPLACE WITH YOUR OWN VALUES
# Avi Controller Version
variable "avi_version" {
  default = "22.1.1"  
}

# REPLACE WITH YOUR OWN VALUES
# Avi Tenant that you would like to deploy these services to (Default is "admin")
variable "avi_tenant" {
  default = "admin"
}

# Name of NSX Cloud
variable "avi_cloud" {
  default = "NSX-Cloud-OTZ"  
}

# Name of SE Group
variable "nsx_se_group" {
  default = "alb-se-group"
}

# NSX Tier1 Logical Router Name
variable "tier1_lr" {
  default = "Demo-NSX-ALB-Data-Tier1-GW"
}

# Variables for Virtual Service Server Pools (DNS Servers)
# Repeat for multiple servers.
variable "server_1" {
  default = "10.16.10.1"
}

variable "server_2" {
  default = "10.16.10.2"
}

# Uncomment Variable if using Static VIP address placement; if using Avi or external IPAM, skip this variable
variable "static_vip" {
  default = "10.100.101.53"  
}

# NSX Segment Name for VIP Network
variable "ipam_network_name" {
  default = "nsx-demo-alb-vip"  
}

# IPv4 Network Address for VIP Network (i.e., 192.168.0.0)
variable "ipam_vip_subnet" {
  default = "10.100.101.0"  
}

# CIDR Prefix for VIP Network (i.e., "24")
variable "ipam_vip_mask" {
  default = "24"  
}

# DNS Profile Variable (i.e., yourdomain.com)
variable "domain" {
  default = "k8s.demo"
}