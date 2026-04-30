# Avi CAC Authentication Demo

This project demonstrates CAC-style certificate authentication with VMware Avi Load Balancer, AD CS-issued certificates, an Avi HTTP Request DataScript, NGINX source enforcement, and a Flask backend portal.

## Traffic Flow

Browser with client cert → Avi Virtual Service → Avi PKI validation → Avi DataScript header assertion → NGINX backend ACL → Flask app

## Quick Install

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
