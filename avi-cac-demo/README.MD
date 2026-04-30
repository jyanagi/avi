# Avi CAC Authentication Demo

This project demonstrates CAC-style certificate authentication with VMware Avi Load Balancer, AD CS-issued certificates, an Avi HTTP Request DataScript, NGINX source enforcement, and a Flask backend portal.

## Traffic Flow

Browser with client cert → Avi Virtual Service → Avi PKI validation → Avi DataScript header assertion → NGINX backend ACL → Flask app

## Web App Install

These actions were performed and tested on Ubuntu 22.04.5 LTS

```bash
git clone https://github.com/jyanagi/avi-cac-demo.git
cd avi-cac-demo
```

Update the `AVI_SE_DATA_CIDR` within .env.cac.demo

```bash
vi .env.cac.demo
```

Run the installation scripot

```bash
chmod +x install.sh
./install.sh
```

## Validate

```bash
sudo systemctl status avi-cac-demo --no-pager
sudo nginx -t
curl http://127.0.0.1:8080/health
```

A `{"status":"ok"}` should be received. If a `connection refused` error is received, this is most likely due to the service still restarting; re-run the `curl` command.

## Avi Configuration

### PKI Profile
Import the AD CS issuinog/root CA certificate into Avi and attach it to a PKI Profile

Example:

```text
PKI Profile: Avi-CAC-Demo-PKI-Profile
CertificateAuthority: DemoRootCA
CRL Check: optional for lab
```

### Application Profile
Enable:

```text
Client SSL Certificate Validation: Require
PKI Profile: Avi-CAC-Demo-PKI-Profile
```

### Datascript
Create:

```text
HTTP Request Event Script
```

### Virtual Service
Create or update an HTTPS Virtual Service

```text
Service Port: 443
SSL: Enabled
Pool:  backend web servers on port 80
Application Profile:  HTTP Profile with Client Certificate Validation
PKI Profile:  AD CS trusted CA
DataScript:  HTTP Request Event Script (use datascripts/avi-cac-auth.lua)
```

## AD CS Certificate and Cert Issuance

### Step 1. Open Certificate Templates Console

Run:

```text
certtmpl.msc
```

Locate **Smartcard Logon Template**
Right click → **Duplicate Template**

Use:

```text
Windows Server 2016 / Windows 10 Compatibility
```

### Step 2. General Tab

Name:

```text
DoD-CAC-User
```

Validity:

* 2 years
* Renewal 6 weeks
- [x] Publish in Active Directory

### Step 3. Request Handling Tab
Purpose:

```text
Signature and smartcard logon
```

Minimum key size:

```text
2048
```

Provider Category:

```text
Key Storage Provider
```

Allow private key to be exported:
*optional for lab
*checked if you want PFX files for easy testing

### Step 4. Cryptography Tab
Provider:

```text
Microsoft Software Key Storage Provider
```

or if using physical smartcards:
*Smart Card CSP
Algorithm:
*RSA
Hash:
*SHA256

### Step 5. Subject Name Tab (VERY IMPORTANT)
Select:

```text
Build from this Active Directory information
```

Subject Name Format:

```text
Common Name
```

- [x] E-mail name (optional)
- [x] User principal name (UPN)

Note: this template will only provide normal AD CN. Later steps will manually override AD user naming to more DoD-inspired naming standards.

### Step 6. Extensions Tab (Critical CAC Behavior)
Open Application Policies / EKU and make sure the following entries exist by default (with the following OIDs):

**Smart Card Logon**

```text
1.3.6.1.4.1.311.20.2.2
```

**Client Authentication**

```text
1.3.6.1.5.5.7.3.2
```

### Step 7. Security Tab
Grant these permissions:

**Authenticated Users**
- [x] Read
- [x] Enroll
- [x] Autoenroll (optional)

Alternatively, you could create a separate Security Group, such as `CAC Users` and grant the permissions

Select **OK** to save and close the template

### Step 8. Publish Template on CA
Run:

```text
certsrv.msc
```

Certificate Template
-> New
-> Certificate Template to Issue
-> select `DoD-CAC-User`

### Step 9. Add CA to NTAuth Store (critica for smart card auth)
On CA/DC:
```powershell
certutil -dspulish -f "C:\Windows\System32\CertSrv\CertEnroll\YOURCA.crt" NTAuthCA
```

Without NTAuth:

Windows may trust the certificate, but AD logon will not treat it as smart card authentication.

### Step 10. Create User Object and Enroll Certificate
On Domain Controller or RSAT, in **Active Directory Users and Computers**, create a user account.

**From Domain-Joined Workstation** (logged in as Domain User):

```text
certmgr.msc
```

Personal → Certificates → Request New Certificate

Select:

```text
DoD-CAC-User
```

Export as:

```text
PFX
```

Note: this is optional and only required if browser does not, by default, import certificates from Windows

### Step 11. Browser Test Against Avi
Open browser and navigate to Avi VIP/FQDN. The browser should prompt for user cert selection (simulating CAC/smart card)