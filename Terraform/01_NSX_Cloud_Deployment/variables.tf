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

### --------- VSPHERE VARIABLES ---------
### Required for Avi NSX Cloud Creation

# REPLACE WITH YOUR OWN VALUES
# vCenter IP Address
variable "vcenter_server_ip" {
  default = "10.15.11.100"  
}

# REPLACE WITH YOUR OWN VALUES
# vCenter Username (i.e., "administrator@local"; If you want to input user, use default = "")
variable "vcenter_username" {
  default = "administrator@vsphere.local"  
}

# REPLACE WITH YOUR OWN VALUES
# vCenter Password (If you want to input password, use default = "")
variable "vcenter_password" {
  default = "VMware1!"  
}

# REPLACE WITH YOUR OWN VALUES
# vCenter Datacenter Name
variable "vcenter_datacenter" {
  default = "Demo-Datacenter"  
}

# REPLACE WITH YOUR OWN VALUES
# vCenter Cluster Name
variable "vcenter_cluster" {
  default = "Demo-Cluster"  
}

# REPLACE WITH YOUR OWN VALUES
# vCenter Content Library (to store Avi OVAs)
variable "vcenter_content_library" {
  default = "NSX ALB CL"  
}

# Name of vCenter Credentials Configuration
variable "vcenter_credentials_name" {
  default = "vCenter Credentials"  
}

# REPLACE WITH YOUR OWN VALUES
# Name of vCenter within Avi
variable "vcenter_name" {
  default = "Demo vCenter"  
}

# Name of Datastore for Service Engine Group Configuration and Placement
variable "vcenter_datastore" {
  default = "RDM-02"
}

# Name of vCenter Folder for Service Engine Group Configuration and Placement
variable "vcenter_folder" {
  default = "AviSeFolder"
}

### --------- NSX VARIABLES ---------
### Required for Avi NSX Cloud Creation

# REPLACE WITH YOUR OWN VALUES
# NSX Cluster/Appliance IP
variable "nsx_cluster_ip" {
  default = "10.15.11.20"  
}

# REPLACE WITH YOUR OWN VALUES
# NSX Username (i.e., "admin"; If you want to input user, use default = "")
variable "nsx_username" {
  default = "admin" 
}

# REPLACE WITH YOUR OWN VALUES
# NSX Password (If you want to input password, use default = "")
variable "nsx_password" {
  default = "VMware1!VMware1!"  
}

# Name of vCenter Credentials
variable "nsx_credentials_name" {
  default = "NSX Credentials"  
}

### --------- AVI NSX CLOUD VARIABLES ---------

# Name of NSX Cloud
variable "avi_cloud_name" {
  default = "NSX-Cloud-OTZ"  
}

# Name of Object Prefix for SE Creation
variable "avi_object_prefix" {
  default = "nsx"  
}

# Name of NSX Overlay Transport Zone
variable "overlay_tz" {
  default = "nsx-overlay-transportzone"  
}

# NSX Transport Zone Type
variable "tz_type" {
  default = "OVERLAY"  
}

# Needed only if implementing VLAN Transport Zones
# Note: You cannot mix Overlay and VLAN TZs in a single NSX Cloud deployment
variable "vlan_tz" {
  default = "nsx-vlan-transportzone"  
}

variable "tz_type_vlan" {
  default = "VLAN" 
}

# NSX Tier1 Logical Router
variable "tier1_gw" {
  default = "Demo-NSX-ALB-Data-Tier1-GW"
}

# NSX Segment Name for SE Management Network
variable "nsx_cloud_mgmt_segment" {
  default = "nsx-demo-alb-mgmt"  
}

# NSX Segment Name for SE Data Network
variable "nsx_cloud_data_segment" {
  default = "nsx-demo-alb-data"  
}

# NSX Segment Name for SE VIP Network
variable "nsx_cloud_vip_segment" {
  default = "nsx-demo-alb-vip"  
}

### --------- AVI IPAM/DNS VARIABLES ---------

# IPAM VIP Segment Network Address
variable "ipam_vip_network" {
  default = "10.100.101.0"  
}

# IPAM VIP Segment Network Prefix (i.e., 24 for /24 (255.255.255.0))
variable "ipam_vip_prefix" {
  default = "24"  
}

# Starting Address for VIP Network Range
variable "ipam_vip_start" {
  default = "10.100.101.101"  
}

# Ending Address for VIP Network Range
variable "ipam_vip_end" {
  default = "10.100.101.199"  
}

# DNS Profile Variable (i.e., yourdomain.com)
variable "domain" {
  default = "k8s.demo"
}

### --------- AVI SERVICE ENGINE GROUP VARIABLES ---------
variable "se_grp_name" {
  default = "alb-se-group"
}

variable "se_name_prefix" {
  default = "alb"
}

