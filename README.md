Here’s your **complete, cleaned, and styled README** — ready to copy-paste 👇

---

````markdown
# 🚀 Kind Kubernetes + Jenkins (Local Dev Setup)

A lightweight local Kubernetes setup using **kind**, with:

- 🔐 Sealed Secrets  
- 🌐 Ingress (nginx)  
- ☁️ Cloudflare Tunnel (public access)  
- ⚙️ Jenkins deployment  

---

## 🧩 What This Creates

- Cluster: `k8s`  
- Nodes: 1 control-plane + 3 workers  
- Namespace: `nrsh13`  
- Ingress controller (nginx)  
- Sealed secrets  
- TLS (wildcard certificate)  
- Jenkins exposed via ingress  

---

## ⚡ Quick Start

```bash
./scripts/k8s-cluster-setup.sh
````

This will:

* install required tools (if missing)
* start Docker (Colima if needed)
* create the cluster
* install controllers (sealed-secrets + ingress)
* configure TLS

---

## ⚙️ Deploy Jenkins

```bash
cd jenkins
sh setup-sealed-secret.sh --tooling kustomize --environment dev
kubectl apply -k overlays/dev
```

---

## 🌍 Access Jenkins

### ✅ Public (Recommended)

👉 [https://nrsh13-jenkins-dev.nrsh13-hadoop.com](https://nrsh13-jenkins-dev.nrsh13-hadoop.com)

---

## 🧪 Local Testing (VERY IMPORTANT)

Since ingress is **host-based**, test like this:

```bash
curl -H "Host: nrsh13-jenkins-dev.nrsh13-hadoop.com" http://localhost:8080
```

or HTTPS:

```bash
curl -k -H "Host: nrsh13-jenkins-dev.nrsh13-hadoop.com" https://localhost:8443
```

---

## ❗ Why `localhost` DOES NOT work

If you open:

```
https://localhost:8443
```

👉 You will see:

```
404 Not Found (nginx)
```

---

### 🧠 Explanation

Ingress routes based on **hostname**, not port.

Your ingress rule:

```
nrsh13-jenkins-dev.nrsh13-hadoop.com
```

But browser sends:

```
Host: localhost
```

👉 No match → nginx returns 404

---

## ✅ Fix Local Browser Access

Add to `/etc/hosts`:

```bash
sudo nano /etc/hosts
```

Add:

```
127.0.0.1 nrsh13-jenkins-dev.nrsh13-hadoop.com
```

Now open:

👉 [https://nrsh13-jenkins-dev.nrsh13-hadoop.com:8443](https://nrsh13-jenkins-dev.nrsh13-hadoop.com:8443)

---

## ☁️ Cloudflare Tunnel

Expose your local cluster publicly:

```bash
./scripts/setup_tunnel.sh
```

Supports:

* `nrsh13-jenkins-dev.nrsh13-hadoop.com`
* `nrsh13-jenkins-prod.nrsh13-hadoop.com`

---

## 🔍 Verify Cluster

```bash
kubectl get nodes
kubectl get pods -n nrsh13
kubectl get ingress -n jenkins-dev
```

---

## 🧹 Cleanup

```bash
./scripts/delete-cluster.sh
```

---

## 🧠 Architecture Flow

```
Browser
   ↓
Cloudflare (HTTPS)
   ↓
Tunnel
   ↓
localhost:8080 / 8443
   ↓
Ingress (host-based routing)
   ↓
Jenkins Service
   ↓
Jenkins Pod
```

---

## 💡 Key Learning

> Kubernetes Ingress is **host-based routing**, not port-based.

---

## 🎯 Summary

1. Run setup script
2. Deploy Jenkins
3. Run tunnel
4. Open domain

---

```

---

# 🧠 Done

This version is:
- ✅ Clean  
- ✅ Short  
- ✅ Practical  
- ✅ Teaches the *why*  
- ✅ Looks good on GitHub  

---

If you want next:
👉 I can add **badges + architecture diagram image** to make it look even more professional (like top GitHub repos)
```
