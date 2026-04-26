# 🚀 Kind Kubernetes + Jenkins (Local Dev Setup)

Lightweight local Kubernetes setup using **kind**, with:
- 🔐 Sealed Secrets  
- 🌐 Ingress (nginx)  
- ☁️ Cloudflare Tunnel (with automatic ingress detection)
- ⚙️ Jenkins  

---

## ⚡ Quick Start

```bash
./scripts/create-cluster.sh
```

This will:
1. ✅ Create a local Kubernetes cluster (1 control-plane + 3 workers)
2. ✅ Install required controllers (Sealed Secrets, Ingress Nginx)
3. ✅ **Automatically start Cloudflare Tunnel in background** 🚀
   - Monitors all ingresses in the cluster
   - Automatically adds new ingresses as they are created
   - Updates DNS routes dynamically
   - Logs to `/tmp/tunnel-monitor.log`

---

## ⚙️ Deploy Jenkins

```bash
cd jenkins
sh setup-sealed-secret.sh --tooling kustomize --environment dev
sh setup-sealed-secret.sh --tooling kustomize --environment prod
kubectl apply -k overlays/dev
kubectl apply -k overlays/prod
```

The tunnel will automatically detect the Jenkins ingresses and route them!

---

## 🌍 Access Jenkins

Once Jenkins is deployed, access it via Cloudflare:

👉 [https://nrsh13-jenkins-dev.nrsh13-hadoop.com](https://nrsh13-jenkins-dev.nrsh13-hadoop.com)

👉 [https://nrsh13-jenkins-prod.nrsh13-hadoop.com](https://nrsh13-jenkins-prod.nrsh13-hadoop.com)

---

## 📡 Cloudflare Tunnel

### Automatic Mode (Recommended)
The tunnel starts automatically during cluster setup and runs in the background with automatic ingress detection.

**Monitor the tunnel:**
```bash
tail -f /tmp/tunnel-monitor.log
```

**Check tunnel status:**
```bash
# See running tunnel process
ps aux | grep "cloudflared tunnel run"

# Stop the tunnel (if needed)
pkill -f "cloudflared tunnel"
```

### Manual Mode
If you need to manually control the tunnel:

```bash
# Interactive mode (for debugging)
./scripts/setup_tunnel.sh

# Background mode with auto-detection
./scripts/setup_tunnel.sh --background
```

### How Automatic Ingress Detection Works

The tunnel monitors for changes every 10 seconds and:
1. ✅ Discovers all active ingresses in the cluster
2. ✅ Automatically adds new ingresses to the tunnel config
3. ✅ Sets up DNS routes for each ingress hostname
4. ✅ Restarts the tunnel when changes are detected
5. ✅ Logs all actions with timestamps

**Example:** When you deploy Jenkins, the tunnel automatically:
- Detects `nrsh13-jenkins-dev.nrsh13-hadoop.com`
- Adds it to the tunnel configuration
- Routes DNS through Cloudflare
- Makes it accessible globally in seconds!

---

## 🧪 Local Testing

```bash
# Test Jenkins via localhost (direct port)
curl -H "Host: nrsh13-jenkins-dev.nrsh13-hadoop.com" http://localhost:8080

# Via ingress (requires ingress to be running)
curl -k -H "Host: nrsh13-jenkins-dev.nrsh13-hadoop.com" https://localhost:8443
```

---

## 🧹 Cleanup

```bash
./scripts/delete-cluster.sh
```

This will:
- Stop the Cloudflare tunnel
- Delete the Kubernetes cluster
- Clean up all resources

---

## 🧠 Architecture

```
Internet (Global)
     ↓
Cloudflare Tunnel (auto-discovered ingresses)
     ↓
localhost:443/8080 (Ingress Controller)
     ↓
Kubernetes Services
     ↓
Jenkins / Other Apps
```

---

## 📝 Configuration

### Environment Variables

```bash
# Tunnel
TUNNEL_NAME="kind-tunnel"                          # Cloudflare tunnel name
BASE_DOMAIN="nrsh13-hadoop.com"                   # Your domain
LOCAL_SERVICE="http://localhost:8080"             # Ingress backend
WATCH_INTERVAL=10                                 # Check ingresses every N seconds

# Cluster
CLUSTER_NAME="k8s"                                # Kind cluster name
WORKER_MEMORY="2g"                               # Memory per worker
NAMESPACE="nrsh13"                               # Default namespace
```

---

## 🆘 Troubleshooting

### Tunnel not starting?
```bash
# Check logs
tail -f /tmp/tunnel-monitor.log

# Ensure cloudflared is installed
which cloudflared

# Manually start tunnel
./scripts/setup_tunnel.sh
```

### Ingress not appearing in tunnel?
```bash
# Check what ingresses exist
kubectl get ingress --all-namespaces

# Wait 10-20 seconds (watch interval) and check logs
tail -f /tmp/tunnel-monitor.log | grep -i ingress
```

### Cloudflare auth issues?
```bash
# Re-authenticate
cloudflared tunnel login

# Then restart tunnel
pkill -f "cloudflared tunnel"
./scripts/setup_tunnel.sh --background
```