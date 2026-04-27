# Avi Load Balancer

Avi Load Balancer is a software-defined load balancing solution that provides advanced traffic management, application delivery, and analytics for modern applications.

## Features

- **Multi-Cloud Support**: Deploy across multiple cloud platforms including AWS, Azure, GCP, and on-premises.
- **Advanced Load Balancing**: Layer 4-7 load balancing with intelligent traffic distribution.
- **Application Analytics**: Real-time insights into application performance and user experience.
- **Security**: Built-in WAF, DDoS protection, and SSL/TLS termination.
- **Automation**: RESTful APIs and integrations with infrastructure automation tools like Terraform.

## Prerequisites

- Avi Controller deployed in your environment
- Network connectivity to Avi Service Engines
- Appropriate licenses for Avi Load Balancer features

## Installation

### Terraform Deployment

This repository includes Terraform configurations for deploying Avi Load Balancer components:

1. **NSX Cloud Deployment** (`Terraform/01_NSX_Cloud_Deployment/`):
   - Deploys Avi in NSX-T environment
   - Configures cloud connector for NSX integration

2. **DNS Virtual Service** (`Terraform/02_Deploy_DNS_VS/`):
   - Deploys DNS-based virtual services
   - Configures DNS load balancing

### Manual Deployment

1. Download Avi Controller OVA/AMI from Avi Networks
2. Deploy Avi Controller in your virtualization/cloud platform
3. Configure initial setup via web interface
4. Deploy Service Engines as needed

## Usage

### Basic Configuration

1. Access Avi Controller web interface
2. Create virtual services for your applications
3. Configure pools and health monitors
4. Apply security policies and analytics profiles

### API Usage

```bash
# Example API call to create a virtual service
curl -X POST -H "Content-Type: application/json" \
  -d '{"name":"my-app","vip":[{"ip_address":{"addr":"10.0.0.1","type":"V4"}}]}' \
  https://avi-controller/api/virtualservice
```

### Terraform Usage

```bash
cd Terraform/01_NSX_Cloud_Deployment
terraform init
terraform plan
terraform apply
```

## Configuration

### ako/ Directory

Contains Helm values for Avi Kubernetes Operator (AKO) deployment:

- `values.yaml`: Configuration values for AKO installation

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

This project is licensed under the Apache 2.0 License - see the LICENSE file for details.

## Support

For support and documentation, visit:
- [Avi Networks Documentation](https://avinetworks.com/docs/)
- [Avi Community](https://avinetworks.com/community/)

## Disclaimer

This repository contains example configurations and is not officially supported by Avi Networks. Use at your own risk.