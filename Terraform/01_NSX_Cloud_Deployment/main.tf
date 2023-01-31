terraform {
  required_providers {
    avi = {
      source = "vmware/avi"
      version = "22.1.2"
    }
    vsphere = {
      source = "hashicorp/vsphere"
    }
    nsxt = {
      source = "vmware/nsxt"
      version = "3.2.5"
    }
  }
}

provider "avi" {
  avi_username = var.avi_username
  avi_password = var.avi_password
  avi_tenant = var.avi_tenant
  avi_controller = var.avi_controller_ip
  avi_version = var.avi_version
} 

provider "vsphere"{
  user = var.vcenter_username
  password = var.vcenter_password
  vsphere_server = var.vcenter_server_ip
  allow_unverified_ssl = true
}

provider "nsxt"{
  host = var.nsx_cluster_ip
  username = var.nsx_username
  password = var.nsx_password
  allow_unverified_ssl = true
}

### --------- DATA SOURCES ---------

## Avi Data Sources ------

data "avi_tenant" "tenant" {
  name = var.avi_tenant
}

data "avi_cloud" "nsx_cloud" {
  name = var.avi_cloud_name
}

data "avi_cloud" "default_cloud" {
  name = "Default-Cloud"
}

data "avi_ipamdnsproviderprofile" "ipam_profile" {
  name = avi_ipamdnsproviderprofile.ipam_profile.id
}

data "avi_vrfcontext" "vrf_context" {
  name = var.tier1_gw
}
## vSphere Data Sources ------

data "vsphere_content_library" "content_library" {
  name = var.vcenter_content_library
}

data "vsphere_datacenter" "vc_datacenter" {
  name = var.vcenter_datacenter
}

data "vsphere_datastore" "vc_datastore" {
  name = var.vcenter_datastore
  datacenter_id = data.vsphere_datacenter.vc_datacenter.id
}

data "vsphere_compute_cluster" "vc_cluster" {
	name = var.vcenter_cluster
	datacenter_id = data.vsphere_datacenter.vc_datacenter.id
}

## NSX Data Sources ------

data "nsxt_transport_zone" "nsx_tz_name" {
  display_name = var.overlay_tz
  # Uncomment if using VLAN Transport Zones
  #display_name = var.vlan_tz
}

### --------- CREATE AVI RESOURCES ---------

# Creating NSX Credentials Configuration
resource "avi_cloudconnectoruser" "nsx_cred" {
  name = var.nsx_credentials_name
  tenant_ref = data.avi_tenant.tenant.id
  nsxt_credentials {
    username = var.nsx_username
    password = var.nsx_password
  }
}

# Creating vSphere Credentials Configuration
resource "avi_cloudconnectoruser" "vcenter_cred" {
  name = var.vcenter_credentials_name
  tenant_ref = data.avi_tenant.tenant.id
  vcenter_credentials {
    username = var.vcenter_username
    password = var.vcenter_password
  }
}

# Create NSX Cloud Network for VIP
# Required to instantiate IPAM Profile for NSX Cloud
resource "avi_network" "default_vip_network" {
  depends_on = [avi_cloudconnectoruser.nsx_cred]
  cloud_ref = data.avi_cloud.default_cloud.id
  tenant_ref = data.avi_tenant.tenant.id
  name = var.nsx_cloud_vip_segment
  dhcp_enabled = false
  #set to true if using IPv6
  ip6_autocfg_enabled = false
  configured_subnets {
    prefix {
      ip_addr {
        addr = var.ipam_vip_network
        type = "V4"
      }
      mask = var.ipam_vip_prefix
    }
    static_ip_ranges {
      type = "STATIC_IPS_FOR_VIP"
      range {
        begin {
          addr = var.ipam_vip_start
          type = "V4"
        }
        end {
          addr = var.ipam_vip_end
          type = "V4"
        }
      }
    }
  }
}

# Create IPAM Profile with VIP Network
resource "avi_ipamdnsproviderprofile" "ipam_profile" {
  depends_on = [avi_network.default_vip_network]
  tenant_ref = data.avi_tenant.tenant.id
  name = "NSX Cloud IPAM"
  type = "IPAMDNS_TYPE_INTERNAL"
  internal_profile {
    usable_networks {
      nw_ref = avi_network.default_vip_network.id
    }
  }
}

# Create DNS Profile with DNS Domain(s)
resource "avi_ipamdnsproviderprofile" "dns_profile" {
  depends_on = [avi_ipamdnsproviderprofile.ipam_profile]
  tenant_ref = data.avi_tenant.tenant.id
  type = "IPAMDNS_TYPE_INTERNAL_DNS"
  name = "DNS Profile"
  internal_profile {
    dns_service_domain {
      domain_name = var.domain
      pass_through = false
      record_ttl = 30
    }
  }
}

# Create the NSX Cloud 
resource "avi_cloud" "nsx_cloud" {
  depends_on = [avi_ipamdnsproviderprofile.dns_profile]
  name = var.avi_cloud_name
  tenant_ref = data.avi_tenant.tenant.id
  vtype = "CLOUD_NSXT"
  dhcp_enabled = true
  obj_name_prefix = var.avi_object_prefix
  dns_provider_ref = avi_ipamdnsproviderprofile.dns_profile.id
  ipam_provider_ref = avi_ipamdnsproviderprofile.ipam_profile.id
  nsxt_configuration {
    nsxt_credentials_ref = avi_cloudconnectoruser.nsx_cred.uuid
    nsxt_url = var.nsx_cluster_ip
    management_network_config {
      tz_type = var.tz_type
      transport_zone = "/infra/sites/default/enforcement-points/default/transport-zones/${data.nsxt_transport_zone.nsx_tz_name.id}"
      overlay_segment {
        tier1_lr_id = "/infra/tier-1s/${var.tier1_gw}"
        segment_id = "/infra/segments/${var.nsx_cloud_mgmt_segment}"
      }
    }
    data_network_config {
      tz_type = var.tz_type
      transport_zone = "/infra/sites/default/enforcement-points/default/transport-zones/${data.nsxt_transport_zone.nsx_tz_name.id}"
      tier1_segment_config {
        segment_config_mode = "TIER1_SEGMENT_MANUAL"
        manual {
          tier1_lrs {
            tier1_lr_id = "/infra/tier-1s/${var.tier1_gw}"
            segment_id = "/infra/segments/${var.nsx_cloud_data_segment}"
          }
        }
      }
    }
  }
}

# Associate vCenter Server to Avi NSX Cloud
resource "avi_vcenterserver" "vcenter_server" {
  depends_on = [avi_cloud.nsx_cloud]
  name = var.vcenter_name
  tenant_ref = data.avi_tenant.tenant.id
  cloud_ref = avi_cloud.nsx_cloud.id
  vcenter_url = var.vcenter_server_ip
  content_lib {
    id = data.vsphere_content_library.content_library.id
  }
  vcenter_credentials_ref = avi_cloudconnectoruser.vcenter_cred.uuid
}

# Create new SE Group for Virtual Services
resource "avi_serviceenginegroup" "alb-se-group" {
  name = var.se_grp_name
  cloud_ref = avi_cloud.nsx_cloud.id
  tenant_ref = data.avi_tenant.tenant.id
  se_name_prefix = var.se_name_prefix
  max_se = 2
  # Setting 'se_deprovision_delay' to '0' forces retention of SEs indefinitely. Unit is measured in min [0-525600]
  se_deprovision_delay = 0
  # Options to specify SE Placement within vCenter
  vcenters {
    vcenter_ref = avi_vcenterserver.vcenter_server.id
    vcenter_folder = var.vcenter_folder
    nsxt_clusters {
      cluster_ids = [data.vsphere_compute_cluster.vc_cluster.id]
      include = true
    }
    nsxt_datastores {
      ds_ids = [data.vsphere_datastore.vc_datastore.id]
      include = true
    }
  }
}


