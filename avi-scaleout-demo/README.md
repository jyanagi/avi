# Avi Live Elastic Scale-out Demo

<img src="images/scaleout-dashboard.png" alt="Avi Scaleout Demo Dashboard" width="100%"/>

This project provides a live demonstration of Avi Load Balancer Virtual Service scale-out and scale-in. It is not a simulation. The application discovers Virtual Services in a configured Avi cloud and Service Engine Group, reads live analytics and placement data, generates sustained TCP connections against the selected VIP, and displays topology and phase changes in a presenter-friendly web interface.

## Safety

Use this application only against a lab Virtual Service that you are authorized to test. The generator creates real network connections. It is capped at 400 new connections per second and 1,500 held connections, but lower demonstration values are strongly recommended.

## Requirements

- Node.js 18 or newer
- Network and DNS access from the application host to the Avi Controller
- Network access from the application host to the selected Virtual Service
- An Avi account with permission to read analytics, placement, Service Engines, pools, and Virtual Services
- Permission to request Virtual Service scale-in if accelerated Phase 6 reset is used

The project has no external npm dependencies.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8080` | Web server listening port |
| `AVI_CONTROLLER` | `us-east-avi.demo.lab` | Avi Controller hostname |
| `AVI_USERNAME` | `admin` | Avi username |
| `AVI_PASSWORD` | None | Avi password, required |
| `AVI_API_VERSION` | `32.1.1` | Avi API version header |
| `AVI_CLOUD` | `Demo NSX Cloud` | Avi cloud name |
| `AVI_SE_GROUP` | `Scaleout-SEG` | Service Engine Group name |
| `AVI_TLS_VERIFY` | `false` | Set to `true` when the controller certificate is trusted |
| `AUTO_RESET_SECONDS` | `30` | Stabilization time before load is released |
| `SCALEIN_QUIET_SECONDS` | `90` | Quiet period before scale-in, minimum 30 seconds |

## Avi Service Engine Group Auto-Rebalance

Avi Service Engine Group auto-rebalance allows the Avi Controller to automatically redistribute or scale Virtual Services when the load on the Service Engines (SEs) exceeds or falls below configured capacity thresholds.

Auto-rebalance can evaluate several load criteria at the Service Engine level:

- Packets per second (PPS)
- Throughput in Mbps
- Open connections
- CPU utilization

This demo uses **Open Connections** as the auto-rebalance criterion. Open connections provide a predictable and repeatable way to demonstrate scale-out because the load generator can establish and maintain a known number of concurrent TCP connections through the Virtual Service.

### Configure Auto-Rebalance

The following settings are intentionally tuned for a lab and demonstration environment to make the scale-out behavior easier to trigger and observe.

```bash
configure serviceenginegroup <your-se-group-name>
auto_rebalance
auto_rebalance_interval 10
auto_rebalance_criteria SE_AUTO_REBALANCE_OPEN_CONNS
auto_rebalance_capacity_per_se 50
auto_rebalance_cool_down_time 1
auto_rebalance_raise_events_for_actions
auto_rebalance_dry_run_enabled false
max_cpu_usage 60
min_cpu_usage 20
save
```

The configuration controls the auto-rebalance behavior as follows:

- **`auto_rebalance`** enables automatic rebalance actions. When enabled, Avi can take action instead of only identifying an imbalance condition.

- **`auto_rebalance_interval 10`** configures the Controller to evaluate the Service Engine Group for rebalance opportunities every 10 seconds. The shorter interval is useful for a demonstration because changes in load are evaluated more frequently.

- **`auto_rebalance_criteria SE_AUTO_REBALANCE_OPEN_CONNS`** configures the number of open connections as the load criterion used for the rebalance decision. In this demo, the load generator creates sustained connections through the Virtual Service to drive this metric.

- **`auto_rebalance_capacity_per_se 50`** defines the configured capacity value associated with the selected auto-rebalance criterion. Because the selected criterion is `SE_AUTO_REBALANCE_OPEN_CONNS`, the value is associated with open-connection capacity. The value of `50` is intentionally aggressive for this demo so that the overloaded condition is easy to produce. This should not be treated as a recommended production capacity setting.

- **`auto_rebalance_cool_down_time 1`** configures a one-minute cooldown period following an auto-rebalance action. The cooldown prevents Avi from immediately performing another rebalance operation while the environment is stabilizing.

- **`auto_rebalance_raise_events_for_actions`** enables Avi event generation for auto-rebalance actions. This is useful during the demo because scale-out and rebalance activity can be correlated with Controller events.

- **`auto_rebalance_dry_run_enabled false`** allows Avi to perform the calculated rebalance action. When dry-run mode is enabled, Avi can evaluate and report rebalance decisions without actually performing the corresponding scale operation.

- **`max_cpu_usage 60`** sets the upper Service Engine CPU utilization threshold to 60 percent. The primary auto-rebalance criterion demonstrated in this example remains open connections.

- **`min_cpu_usage 20`** sets the lower Service Engine CPU utilization threshold to 20 percent. This helps define when an SE may be considered underutilized. CPU utilization is not the primary scale-out criterion used by this demo.

### Verify Auto-Rebalance Configuration

After saving the Service Engine Group configuration, verify the relevant settings:

```bash
show serviceenginegroup <your-se-group-name> | grep -E 'auto_rebalance|cpu_usage'
```

Example output:

```text
| max_cpu_usage                                 | 60 percent                                              |
| min_cpu_usage                                 | 20 percent                                              |
| auto_rebalance                                | True                                                    |
| auto_rebalance_interval                       | 10 sec                                                  |
| auto_rebalance_criteria[1]                    | SE_AUTO_REBALANCE_OPEN_CONNS                            |
| auto_rebalance_capacity_per_se[1]             | 50                                                      |
| auto_rebalance_cool_down_time                 | 1 min                                                   |
| auto_rebalance_raise_events_for_actions       | True                                                    |
| auto_rebalance_dry_run_enabled                | False                                                   |
```

### Demo Behavior

The demo begins with the Virtual Service active on two Service Engines while a third Service Engine is available in the Service Engine Group. The load generator establishes and maintains concurrent connections through the Virtual Service.

As the open-connection load increases, the Avi Controller periodically evaluates the Service Engine Group using the configured `SE_AUTO_REBALANCE_OPEN_CONNS` criterion. When Avi determines that additional capacity is required, the Virtual Service is scaled out to the third Service Engine.

The expected transition is:

```text
2 Service Engines supporting the Virtual Service
                    |
                    | Sustained connection load
                    v
3 Service Engines supporting the Virtual Service
```

The third Service Engine is already provisioned for this demo. Therefore, the demonstration focuses on **dynamic Virtual Service scale-out and placement**, rather than the time required to deploy and initialize a new Service Engine virtual machine.

> **Note:** These values are optimized for demonstrating Avi auto-rebalance behavior in a controlled lab. Production values should be determined from actual application traffic patterns, Service Engine sizing, capacity requirements, and operational objectives.

## Local run

PowerShell:

```powershell
$env:AVI_PASSWORD = Read-Host "Avi admin password" -MaskInput
$env:PORT = "8080"
npm start
```

Linux:

```bash
export AVI_PASSWORD='replace-with-password'
export PORT=8080
npm start
```

Open `http://localhost:8080`, replacing the port if `PORT` was changed.

## CentOS Stream 9 installation

```bash
sudo dnf module install -y nodejs:20
sudo git clone YOUR_REPOSITORY_URL /opt/avi-scaleout-demo
cd /opt/avi-scaleout-demo
sudo npm install --omit=dev
sudo cp deploy/avi-scaleout-demo.env.example /etc/avi-scaleout-demo.env
sudo chmod 600 /etc/avi-scaleout-demo.env
sudo cp deploy/avi-scaleout-demo.service /etc/systemd/system/avi-scaleout-demo.service
sudo vi /etc/avi-scaleout-demo.env
sudo systemctl daemon-reload
sudo systemctl enable --now avi-scaleout-demo
sudo systemctl status avi-scaleout-demo
```

Set the real password and confirm the controller, cloud, Service Engine Group, and port in `/etc/avi-scaleout-demo.env` before starting the service.

If firewalld is enabled, open the configured port. This example uses port 5480:

```bash
sudo firewall-cmd --permanent --add-port=5480/tcp
sudo firewall-cmd --reload
```

Open `http://SERVER_NAME:5480` in a browser.

## Changing the listening port

Edit `/etc/avi-scaleout-demo.env` and change `PORT`:

```text
PORT=5480
```

Restart the service and update the firewall or reverse proxy:

```bash
sudo systemctl restart avi-scaleout-demo
```

## Presenter workflow

1. Select a discovered Virtual Service.
2. Set a conservative connections-per-second rate and maximum held connections.
3. Select `Generate load`.
4. Watch live connections, throughput, packet rate, placement, and Service Engine count.
5. Wait for Avi to attach an additional Service Engine to the VIP.
6. Allow the automatic reset or select `Stop` to close all generated connections.
7. Watch Avi return the VIP to its baseline Service Engine placement.

The event stream distinguishes the total SEG inventory from the Service Engines supporting the selected VIP. Scale-out and scale-in are reported only after live placement telemetry confirms the change.

## Troubleshooting

Check application health:

```bash
curl -s http://127.0.0.1:5480/api/health
```

Confirm timer configuration:

```bash
curl -s http://127.0.0.1:5480/api/avi/discover | jq '.demo'
```

View service logs:

```bash
sudo journalctl -u avi-scaleout-demo -f
```

View background-only scale-in diagnostics:

```bash
sudo journalctl -u avi-scaleout-demo -f | grep --line-buffered '\[scale-in\]'
```

If Virtual Services do not load, verify that the application host can resolve and reach the controller and that `AVI_PASSWORD` is present in the environment file.

## Repository contents

- `server.js`: Node.js web server, Avi API integration, and connection generator
- `public/`: Frontend HTML, JavaScript, and styles
- `deploy/`: CentOS environment and systemd templates
- `config.example.json`: Reference configuration without credentials
- `package.json`: Node.js package metadata and scripts

