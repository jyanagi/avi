# Avi Controller Ansible Deployment

This project deploys one or three VMware Avi Load Balancer Controller nodes to vCenter using Ansible, bootstraps each Controller, and optionally forms a three-node cluster.

## Requirements

- A RHEL/CentOS-family host (or similar) with `python3.11` or newer available
- Access to a vCenter environment with a content library containing an Avi Controller OVA
- Network access to `github.com`, `pypi.org`, and `galaxy.ansible.com` (or an internal mirror) from the Ansible control host

## 1. Set up a Python virtual environment

The system Python on many RHEL-family hosts is too old for current Ansible collections. Build an isolated environment instead of touching the system install.

```bash
python3.11 -m venv ~/venvs/avi-ansible
source ~/venvs/avi-ansible/bin/activate
pip install --upgrade pip
```

Activate this environment every time you work on this project:

```bash
source ~/venvs/avi-ansible/bin/activate
```

## 2. Install Python dependencies

Save the following as `requirements.txt` in your project directory.

```
ansible-core==2.19.11
requests
pyOpenSSL
pyvmomi
setuptools<81
vsphere-automation-sdk @ git+https://github.com/vmware/vsphere-automation-sdk-python.git
```

Install it:

```bash
pip install -r requirements.txt
```

Notes on this step:

- The `setuptools<81` pin is required. Newer setuptools releases have deprecated `pkg_resources`, which the vSphere Automation SDK still depends on. Without this pin, imports fail with `ModuleNotFoundError: No module named 'pkg_resources'`.
- The vSphere Automation SDK is not on PyPI under a simple package name. It installs directly from its GitHub repository.
- If your host restricts outbound network access, confirm `github.com` and `codeload.github.com` are reachable before running this step.

## 3. Install Ansible collections

Save the following as `requirements.yml`.

```yaml
collections:
  - name: vmware.vmware
  - name: community.vmware
  - name: vmware.alb
```

Install:

```bash
ansible-galaxy collection install -r requirements.yml --force
```

If you hit certificate errors pulling from Galaxy (for example, behind a proxy doing TLS inspection), you can bypass validation for this command only:

```bash
ansible-galaxy collection install -r requirements.yml --force --ignore-certs
```

Confirm the collections installed correctly:

```bash
ansible-galaxy collection list
```

You should see `vmware.vmware`, `community.vmware`, and `vmware.alb` listed with version numbers.

## 4. Configure variables

Create `vars.yml` in your project directory and fill in values for your environment.

```yaml
# vCenter connection
vcenter_hostname: "vc01.demo.lab"
vcenter_username: "administrator@vsphere.local"
vcenter_password: "{{ vault_vcenter_password }}"

# Deployment target
datacenter_name: "Datacenter1"
datastore_name: "datastore1"
resource_pool_name: "Resources"
management_network: "Management-PG"

# Content library source
library_name: "your-content-library-name"
library_item_name: "controller-32.1.1-9129"

# Cluster sizing
# Set to 1 for a single node, 3 for a three-node cluster
cluster_size: 3

# Network settings applied to every node
controller_mask: "255.255.255.0"
controller_gw: "10.10.10.1"

# Cluster identity (only used when cluster_size is 3)
cluster_name: "avi-cluster-01"
cluster_vip: "10.10.10.60"

# Controller node identities
# Only the first `cluster_size` entries are used
all_controllers:
  - vm_name: "avi-controller-01"
    ip: "10.10.10.50"
  - vm_name: "avi-controller-02"
    ip: "10.10.10.51"
  - vm_name: "avi-controller-03"
    ip: "10.10.10.52"

# Avi API version to target
avi_api_version: "32.1.1"

# System Configuration
avi_ntp_servers:
  # For FQDN entries
  - server:
      addr: "0.us.pool.ntp.org"
      type: "DNS"
  - server:
      addr: "1.us.pool.ntp.org"
      type: "DNS"
  - server:
      addr: "2.us.pool.ntp.org"
      type: "DNS"
  - server:
      addr: "3.us.pool.ntp.org"
      type: "DNS"
  # For IPv4 entries
  - server:
      addr: "66.118.228.14"
      type: "V4"
  - server:
      addr: "69.30.247.121"
      type: "V4"

avi_dns_servers:
  - addr: "8.8.8.8"
    type: "V4"
  - addr: "8.8.4.4"
    type: "V4"

avi_dns_search_domain: "acme.com"
```

## 5. Configure secrets with Ansible Vault

Sensitive values are kept separate from `vars.yml` and encrypted.

Create the encrypted file:

```bash
ansible-vault create vault.yml
```

This opens your default editor. Enter the following, replacing the placeholder values:

```yaml
vault_vcenter_password: "your-vcenter-password"
vault_avi_initial_password: "the-controller-default-password"
vault_avi_admin_password: "your-new-admin-password"
```

To edit this file later without decrypting it manually:

```bash
ansible-vault edit vault.yml
```

Notes on the initial admin password:

Current Avi Controller are pre-configured with a default admin password on first boot. This password can be downloaded (Default_password.txt) from the Avi product files within the Broadcom Support Portal. 

## 6. Run the playbook

The full playbook is `deploy-avi.yml`. Tasks are organized under tags so you can run the whole thing or resume partway through.

Run everything, start to finish:

```bash
ansible-playbook deploy-avi.yml --ask-vault-pass
```

Run specific stages:

```bash
# Deploy VMs only
ansible-playbook deploy-avi.yml --ask-vault-pass --tags deploy

# Network configuration only
ansible-playbook deploy-avi.yml --ask-vault-pass --tags network

# Power on only
ansible-playbook deploy-avi.yml --ask-vault-pass --tags poweron

# Bootstrap (wait for boot, set password, complete welcome workflow)
ansible-playbook deploy-avi.yml --ask-vault-pass --tags bootstrap

# Cluster formation and readiness check
ansible-playbook deploy-avi.yml --ask-vault-pass --tags cluster
```

You can also resume from a specific task by name if a run fails partway through:

```bash
ansible-playbook deploy-avi.yml --ask-vault-pass --start-at-task="Wait for each Controller's management port to come up"
```

## What the playbook does, in order

1. Deploys one or three Controller VMs from the specified content library item.
2. Sets the management network and vApp properties (management IP, subnet mask, default gateway) on each VM.
3. Powers on each VM.
4. Waits for each Controller's management port to respond, then confirms the API is reachable.
5. Logs in with the initial (factory or generated) password and changes the admin password to the value in `vault.yml`.
6. Marks the first-boot welcome workflow as complete on each node. This step is required. Skipping it causes cluster formation to fail with a misleading "login failed" error even when the password is correct.
7. If `cluster_size` is set to 3, builds a cluster node list and forms the cluster, then polls until all three nodes appear in the cluster status.

## Known behavior and troubleshooting

**"Login with admin credentials provided failed" during cluster formation, even with a correct password.**
This almost always means the welcome workflow has not been completed on the target node. Confirm by logging in to the node and checking `system_config.welcome_workflow_complete` in the response from `/api/systemconfiguration`. If it shows `false`, rerun the bootstrap tag.

**HTTP 423 "Account locked" errors.**
Avi Controller locks the admin account after repeated failed login attempts. The lockout timer resets on each additional failed attempt made while the account is already locked, so repeatedly testing during a lockout window extends it rather than clearing it. If you hit this, stop making any requests to that node for several minutes before trying again.

**"Controller is not yet ready" (HTTP 503) after cluster formation starts.**
This is normal. Cluster formation restarts internal services on each node and can take several minutes. Poll `/api/cluster` using session authentication (not Basic Auth, which this endpoint rejects) until the response includes a `nodes` array with the expected number of entries.

**Basic Authentication failures on state-changing endpoints.**
Avi Controller does not accept HTTP Basic Authentication for most POST/PUT operations by default. Use session authentication instead: log in via `POST /login` to obtain a `sessionid` and `csrftoken` cookie, then include both on subsequent requests via the `Cookie` and `X-CSRFToken` headers.

**Ansible `until` combined with `loop` does not retry per item.**
When a task uses both `until`/`retries` and `loop`, only the last item in the loop is actually retried on failure. Earlier items run once and fail without retrying. For polling tasks that need to loop over multiple hosts, use `ansible.builtin.wait_for` instead, which handles its own internal polling correctly per loop item.

## Rebuilding this environment from scratch

```bash
python3.11 -m venv ~/venvs/avi-ansible
source ~/venvs/avi-ansible/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml --force
```

Then confirm versions:

```bash
ansible --version
python --version
ansible-galaxy collection list
```
