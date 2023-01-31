terraform {
  required_providers {
    avi = {
      source = "vmware/avi"
      version = "22.1.2"
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

### --------- DATA SOURCES ---------

data "avi_tenant" "admin" {
  name = var.avi_tenant
}

data "avi_cloud" "nsx_cloud" {
  name = var.avi_cloud
}

data "avi_cloud" "default_cloud" {
  name = "Default-Cloud"
}

data "avi_serviceenginegroup" "nsx_se_group" {
  name = var.nsx_se_group
}

data "avi_applicationprofile" "application_dns_profile" {
  name = "System-DNS"
 }

data "avi_networkprofile" "network_dns_profile" {
  name = "System-UDP-Per-Pkt"
 }

data "avi_network" "vip_network" {
  name = var.ipam_network_name
  cloud_ref = data.avi_cloud.default_cloud.id
}

### --------- CREATE AVI RESOURCES ---------

# System-DNS Health Monitor Configuration

resource "avi_healthmonitor" "system_dns_hm" {
  name = "AKO-DNS-HM"
  type = "HEALTH_MONITOR_DNS"
  tenant_ref = data.avi_tenant.admin.id
  dns_monitor {
    qtype = "DNS_QUERY_TYPE"
    query_name = "www.google.com"
    rcode = "RCODE_NO_ERROR"
    record_type = "DNS_RECORD_A"
    }
  is_federated = false
  send_interval = "6"
  receive_timeout = "4"
  successful_checks = "2"
  failed_checks = "2"
}

# DNS Server Pool Configuration

resource "avi_pool" "dns_server_pool" {
  name = "AKO-DNS-Vs-pool"
  health_monitor_refs = [avi_healthmonitor.system_dns_hm.id]
  tenant_ref = data.avi_tenant.admin.id
  cloud_ref = data.avi_cloud.nsx_cloud.id
  tier1_lr = "/infra/tier-1s/${var.tier1_lr}"
  lb_algorithm = "LB_ALGORITHM_ROUND_ROBIN"
  fail_action {
    type= "FAIL_ACTION_CLOSE_CONN"
  }
}

resource "avi_server" "dns_1" {
    ip = var.server_1
    port = "53"
    pool_ref = avi_pool.dns_server_pool.id
}

resource "avi_server" "dns_2" {
    ip = var.server_2
    port = "53"
    pool_ref = avi_pool.dns_server_pool.id
}

# Virtual Service VIP Configuration

resource "avi_vsvip" "dns_vsvip" {
  name = "AKO-DNS-VsVIP"
  tenant_ref = data.avi_tenant.admin.id
  cloud_ref = data.avi_cloud.nsx_cloud.id
  tier1_lr = "/infra/tier-1s/${var.tier1_lr}"

  vip {
    vip_id = "0"
    # Uncomment the following lines if using Static VIP addressing
    # Comment out "auto-allocate_ip = true" and "auto_allocate_ip_type = "V4_ONLY""
    # ip_address {
    #    type = "V4"
    #    addr = var.static_vip
    #}
    auto_allocate_ip = true
    auto_allocate_ip_type = "V4_ONLY"
    ipam_network_subnet {
      network_ref = data.avi_network.vip_network.id
      subnet {
        mask = var.ipam_vip_mask
        ip_addr {
          type = "V4"
          addr = var.ipam_vip_subnet
        }
      }
    }
  }
}

# Virtual Service Configuration

resource "avi_virtualservice" "test_vs" {
  name = "AKO-DNS-Vs"
  pool_ref = avi_pool.dns_server_pool.id
  cloud_ref = data.avi_cloud.nsx_cloud.id
  tenant_ref = data.avi_tenant.admin.id
  se_group_ref = data.avi_serviceenginegroup.nsx_se_group.id
  application_profile_ref = data.avi_applicationprofile.application_dns_profile.id
  network_profile_ref = data.avi_networkprofile.network_dns_profile.id
  vsvip_ref = avi_vsvip.dns_vsvip.id

  services {
    port= 53
  }
}



