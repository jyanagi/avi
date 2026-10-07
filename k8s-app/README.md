# Avi AKO Demo on Kubernetes

Deploy the Avi demo backend and frontend in the `avi-demo` namespace and expose the frontend through Avi Kubernetes Operator (AKO) at `https://avi-demo.us-east.demo.lab/`.

## Prerequisites

- A Kubernetes cluster supporting `apps/v1` Deployments and `networking.k8s.io/v1` Ingress resources, with `kubectl` configured for the intended cluster.
- Permission to create a namespace and manage Deployments, Services, ServiceAccounts, Ingresses, and AKO HostRules.
- AKO installed, configured to communicate with the Avi Controller, and watching the `avi-demo` namespace. The `ako.vmware.com/v1alpha1` HostRule CRD must be installed, and ingress class `avi-lb` must be configured for AKO.
- The following objects must already exist in the Avi Controller and be accessible in the tenant used by AKO: application profile `System-Secure-HTTP`, WAF policy `WAF-Enforcement-Policy`, SSL profile `System-Standard-PFS`, certificate/key object `us-east-wildcard`, and analytics profile `System-Analytics-Profile`.
- The `us-east-wildcard` certificate must cover `avi-demo.us-east.demo.lab`, with a valid certificate chain and private key. Clients must trust its issuing CA.
- Cluster access to the container images `jefleppard549/avi-demo-backend:latest` and `jefleppard549/avi-demo-frontend:latest`, sufficient compute capacity, and networking between Avi and the Kubernetes services.
- DNS for `avi-demo.us-east.demo.lab` pointing to the virtual IP provisioned by Avi. Configure the record after provisioning if the IP is not known in advance.

Check the target cluster and AKO resources before deployment:

```bash
kubectl config current-context
kubectl cluster-info
kubectl get crd hostrules.ako.vmware.com
kubectl get ingressclass avi-lb
```

## Repository structure

```text
.
├── README.md
├── namespace.yaml
├── backend.yaml
├── frontend.yaml
├── hostrule.yaml
└── ingress.yaml
```

Save the supplied `namespace.yaml` as **`namespace.yaml`** in the repository. Its resource remains the namespace `avi-demo`, labeled `name: avi-demo`. All commands below use the repository filename `namespace.yaml`.

## Manifest overview

### Namespace

`namespace.yaml` creates `avi-demo`. All application resources, the HostRule, and the Ingress belong to this namespace. AKO itself must already be installed; these files deploy the demo application.

### Backend

`backend.yaml` creates a Deployment, ClusterIP Service, and ServiceAccount, each named `avi-demo-backend`.

- The Deployment runs two replicas of `jefleppard549/avi-demo-backend:latest` with `imagePullPolicy: Always`.
- The container listens on TCP port `3000`, with `NODE_ENV=production`, `PORT=3000`, and `DEMO_MODE=true`.
- The Service selects `app: avi-demo-backend` pods and exposes port `3000`, forwarding to the named container port `http` (`3000`). Within the namespace, it is reachable at `avi-demo-backend:3000`.
- Pods use the `avi-demo-backend` ServiceAccount. The manifest creates no additional RBAC bindings.
- HTTP liveness and readiness probes use `/health`. Prometheus scrape annotations advertise `/api/metrics` on port `3000`; these annotations require a monitoring system configured to honor them.
- Each pod requests `100m` CPU and `128Mi` memory, with limits of `500m` CPU and `512Mi` memory.
- The container drops all Linux capabilities and disables privilege escalation. Its root filesystem is writable, and the manifest does not require a non-root user.

### Frontend

`frontend.yaml` creates a Deployment, ClusterIP Service, and ServiceAccount, each named `avi-demo-frontend`.

- The Deployment runs two replicas of `jefleppard549/avi-demo-frontend:latest` with `imagePullPolicy: Always`.
- The Service selects `app: avi-demo-frontend` pods and exposes TCP port `80`, forwarding to the named container port `http` (`80`). This Service is the Ingress target.
- Pods use the `avi-demo-frontend` ServiceAccount. The manifest creates no additional RBAC bindings.
- HTTP liveness and readiness probes use `/index.html`.
- Each pod requests `50m` CPU and `64Mi` memory, with limits of `200m` CPU and `256Mi` memory.
- The container runs as non-root UID `101`, uses a read-only root filesystem, drops all Linux capabilities, and disables privilege escalation. Writable `emptyDir` volumes mount at `/var/cache/nginx` and `/var/run`.

Both Deployments use rolling updates with `maxSurge: 1` and `maxUnavailable: 0`. The images must support the configured probes, ports, and security settings. Because `latest` is mutable, pin image versions or digests when reproducible releases are required.

### AKO HostRule

`hostrule.yaml` creates `avi-demo-hostrule`, an `ako.vmware.com/v1alpha1` HostRule. Its virtual host is enabled for `avi-demo.us-east.demo.lab`, matching the Ingress hostname.

| Setting | Configured value | Purpose |
| --- | --- | --- |
| Application profile | `System-Secure-HTTP` | Applies the referenced Avi application profile. |
| WAF policy | `WAF-Enforcement-Policy` | Applies the referenced web application firewall policy. |
| SSL profile | `System-Standard-PFS` | Applies the referenced TLS profile. |
| Certificate | `us-east-wildcard`, type `ref` | References an existing Avi certificate/key object. |
| TLS termination | `edge` | Terminates client TLS at Avi. |
| Analytics profile | `System-Analytics-Profile` | Applies the referenced analytics profile. |
| Full client logs | Enabled; throttle `DISABLED` | Requests full client logging without throttling. |
| Header logging | `logAllHeaders: true` | Requests logging of all headers. |

The HostRule references existing Avi objects; it does not create those profiles, policies, or the certificate. Edge termination is configured here, rather than through an Ingress `spec.tls` Kubernetes Secret. The manifests do not configure TLS re-encryption to the application pods. Full client and header logging can produce substantial log volume and capture sensitive header values; align retention and access controls with your environment.

### Ingress and request routing

`ingress.yaml` creates `avi-demo-ingress`. Both `spec.ingressClassName` and the `kubernetes.io/ingress.class` annotation specify `avi-lb`.

For host `avi-demo.us-east.demo.lab`, the `/` path uses `pathType: Prefix` and routes to `avi-demo-frontend:80`:

```text
Client HTTPS request
    → Avi virtual host: avi-demo.us-east.demo.lab (TLS termination / WAF)
    → avi-demo-frontend Service:80
    → frontend pod:80
```

The backend is available internally through `avi-demo-backend:3000`. There is no separate Ingress route to the backend in these manifests. Any frontend-to-backend proxying or API integration depends on the application image configuration and should be verified independently. The manifests do not explicitly configure HTTP-to-HTTPS redirection.

## Deployment

Run these commands from the repository root, preserving this exact order:

```bash
kubectl apply -f namespace.yaml
kubectl apply -f backend.yaml
kubectl apply -f frontend.yaml
kubectl apply -f hostrule.yaml
kubectl apply -f ingress.yaml
```

The namespace is created first, followed by the backend and frontend resources. The HostRule is applied before the Ingress so the hostname configuration is available for AKO reconciliation. Applying a resource does not guarantee that it is ready; complete the validation below.

## Validation

Wait for both Deployments to become available:

```bash
kubectl rollout status deployment/avi-demo-backend -n avi-demo --timeout=180s
kubectl rollout status deployment/avi-demo-frontend -n avi-demo --timeout=180s
kubectl get deployments,pods,services,serviceaccounts -n avi-demo
kubectl get endpointslices -n avi-demo -l kubernetes.io/service-name=avi-demo-backend
kubectl get endpointslices -n avi-demo -l kubernetes.io/service-name=avi-demo-frontend
```

Expect two ready replicas per Deployment and ready endpoint addresses for both Services. Inspect the HostRule status for acceptance or rejection details and the Ingress for its assigned address:

```bash
kubectl get hostrules.ako.vmware.com -n avi-demo
kubectl get hostrule avi-demo-hostrule -n avi-demo -o yaml
kubectl describe ingress avi-demo-ingress -n avi-demo
kubectl get ingress avi-demo-ingress -n avi-demo -o wide
```

Once Avi has provisioned the virtual IP, verify DNS and HTTPS access:

```bash
nslookup avi-demo.us-east.demo.lab
curl -v https://avi-demo.us-east.demo.lab/
```

For a private CA, provide its trusted certificate bundle with `curl --cacert /path/to/ca.pem`. To test a known virtual IP before DNS is configured, replace `<AVI_VIP>` below. `--resolve` preserves the hostname for HTTP routing and TLS validation:

```bash
curl -v --resolve avi-demo.us-east.demo.lab:443:<AVI_VIP> https://avi-demo.us-east.demo.lab/
```

In the Avi Controller, verify the virtual host's certificate, application profile, WAF policy, SSL profile, and analytics settings. Generate a request and confirm client logs are recorded. A successful Kubernetes apply alone does not verify those controller settings.

## Troubleshooting

### Pods fail to start or become ready

```bash
kubectl get pods -n avi-demo -o wide
kubectl describe pods -n avi-demo -l app=avi-demo-backend
kubectl describe pods -n avi-demo -l app=avi-demo-frontend
kubectl logs -n avi-demo -l app=avi-demo-backend --all-containers=true --tail=100
kubectl logs -n avi-demo -l app=avi-demo-frontend --all-containers=true --tail=100
kubectl get events -n avi-demo --sort-by=.metadata.creationTimestamp
```

For `ImagePullBackOff`, check registry access and image availability. For probe failures, check `/health` on backend port `3000` and `/index.html` on frontend port `80`. For frontend startup failures, check whether the image can run as UID `101` with a read-only root filesystem and bind port `80` with the configured capabilities. For scheduling failures, check node capacity and admission policy messages in events.

### Isolate application health from Avi routing

Run each port-forward in a separate terminal, then use another terminal for its corresponding request:

```bash
kubectl port-forward -n avi-demo service/avi-demo-backend 3000:3000
```

```bash
curl -v http://localhost:3000/health
```

```bash
kubectl port-forward -n avi-demo service/avi-demo-frontend 8080:80
```

```bash
curl -v http://localhost:8080/index.html
```

Stop each port-forward with Ctrl+C when finished. These checks verify application responses through a forwarded connection; they do not prove Avi-to-cluster networking works.

### HostRule rejection, missing virtual IP, or HTTPS failures

```bash
kubectl describe hostrule avi-demo-hostrule -n avi-demo
kubectl get hostrule avi-demo-hostrule -n avi-demo -o yaml
kubectl describe ingress avi-demo-ingress -n avi-demo
kubectl get ingressclass avi-lb -o yaml
kubectl get pods -A
```

Locate the AKO pod from the final command, then replace the placeholders to inspect its logs:

```bash
kubectl logs -n <AKO_NAMESPACE> <AKO_POD> --all-containers=true --tail=200
```

Check that AKO watches `avi-demo`, processes `avi-lb`, can reach the Avi Controller, and can resolve every referenced profile, policy, and certificate in the correct tenant. Confirm that the HostRule FQDN matches the Ingress host exactly. If HTTPS fails, inspect DNS, VIP reachability, certificate hostname coverage, expiry, and trust chain. If a request is rejected, inspect Avi WAF events and client logs. If the UI loads but API requests fail, inspect the frontend application's backend configuration; the Ingress routes all matching paths to the frontend.

## Cleanup

Delete resources in reverse dependency order, from the repository root:

```bash
kubectl delete -f ingress.yaml --ignore-not-found
kubectl delete -f hostrule.yaml --ignore-not-found
kubectl delete -f frontend.yaml --ignore-not-found
kubectl delete -f backend.yaml --ignore-not-found
kubectl delete -f namespace.yaml --ignore-not-found
```

Deleting `avi-demo` also deletes any other namespaced resources placed there. Confirm that the namespace contains only resources you intend to remove before running the final command. Allow AKO to reconcile removal of the Ingress and verify the associated Avi resources are removed as expected. Remove any DNS record created for this demo separately. Existing Avi profiles, policies, and the referenced certificate are not deleted by these commands.
