# 🚀 Kind Kubernetes + Jenkins (Local Dev Setup)

Lightweight local Kubernetes setup using **kind**, with:
- 🔐 Sealed Secrets  
- 🌐 Ingress (nginx)  
- ☁️ Cloudflare Tunnel  
- ⚙️ Jenkins  

---

## ⚡ Quick Start

```bash
./scripts/k8s-cluster-setup.sh
````

---

## ⚙️ Deploy Jenkins

```bash
cd jenkins
sh setup-sealed-secret.sh --tooling kustomize --environment dev
sh setup-sealed-secret.sh --tooling kustomize --environment prod
kubectl apply -k overlays/dev
kubectl apply -k overlays/prod
```

---

## 🌍 Access Jenkins

👉 [https://nrsh13-jenkins-dev.nrsh13-hadoop.com](https://nrsh13-jenkins-dev.nrsh13-hadoop.com)

👉 [https://nrsh13-jenkins-prod.nrsh13-hadoop.com](https://nrsh13-jenkins-prod.nrsh13-hadoop.com)

---

## 🧪 Local Testing

```bash
curl -H "Host: nrsh13-jenkins-dev.nrsh13-hadoop.com" http://localhost:8080
curl -k -H "Host: nrsh13-jenkins-dev.nrsh13-hadoop.com" https://localhost:8443
https://localhost:8443 - Will not work Because ingress is **host-based routing**.

```

---

## ☁️ Cloudflare Tunnel

```bash
./scripts/setup_tunnel.sh
```

---

## 🧹 Cleanup

```bash
./scripts/delete-cluster.sh
```

---

## 🧠 Flow

```
Browser → Cloudflare → Tunnel → localhost → Ingress → Jenkins
```