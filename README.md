# kind Cluster Setup

This folder sets up a local Kubernetes environment with `kind` on macOS and deploys Jenkins behind `ingress-nginx`, with browser access through your Cloudflare-managed DNS.

## What This Setup Creates

When you run the setup, it:

- creates a `kind` cluster named `dev-cluster`
- creates 1 control-plane node and 2 worker nodes
- sets each worker node to `2 GB` memory
- creates the main admin namespace `nrsh13`
- installs `sealed-secrets` in `nrsh13`
- installs `ingress-nginx` in `nrsh13`
- creates or refreshes the wildcard certificate and TLS secret when needed

## Prerequisites

Before running the scripts, make sure you have:

- macOS
- Homebrew
- Docker Desktop or another Docker-compatible runtime
- access to your Cloudflare account

The setup scripts can install missing local tools such as:

- `kind`
- `kubectl`
- `helm`
- `kubeseal`
- `kustomize`
- `docker`
- `etcd`
- `colima` if Docker runtime is not available

## Cloudflare and DNS Prerequisites

Before using `scripts/setup_tunnel.sh`, your domain must already be managed by Cloudflare.

That means:

1. Your domain exists in Cloudflare.
2. Cloudflare gave you its nameservers for the zone.
3. In AWS Route 53, you updated the domain registration nameservers to the Cloudflare-provided nameservers.
4. Cloudflare is now acting as the active DNS provider for the domain.

For this setup, the public Jenkins hostnames are:

- `nrsh13-jenkins-dev.nrsh13-hadoop.com`
- `nrsh13-jenkins-prod.nrsh13-hadoop.com`

## Create the Cluster

Run:

```bash
cd kind_k8s_cluster_setup
./scripts/k8s-cluster-setup.sh
```

This is now the single setup entry point.

It:

- verifies or installs required tools
- starts Docker runtime if needed
- creates the cluster
- makes sure the cluster has 2 worker nodes
- applies a `2 GB` memory limit to each worker container
- creates namespace `nrsh13` if needed
- installs `sealed-secrets`
- installs `ingress-nginx`
- pins the ingress controller to the control-plane node
- creates or refreshes the wildcard certificate if needed
- creates the sealed TLS secret used by ingress

At the end of cluster setup, it automatically calls:

- `scripts/k8s-controllers-setup.sh`

## Verify the Cluster

Run:

```bash
kubectl cluster-info --context kind-dev-cluster
kubectl get nodes
kubectl get pods -n nrsh13
```

You should see:

- 1 control-plane node
- 2 worker nodes
- `sealed-secrets` running in namespace `nrsh13`
- `ingress-nginx` running in namespace `nrsh13`

## Deploy Jenkins

Jenkins manifests live under `jenkins_kustmize_deploy`.

### Step 1: Generate Sealed Secrets

Run:

```bash
cd kind_k8s_cluster_setup/jenkins_kustmize_deploy
sh setup-sealed-secret.sh --tooling kustomize --environment dev
```

This fetches the active sealed-secrets certificate from the cluster and regenerates the sealed secrets used by the Jenkins dev overlay.

### Step 2: Apply the Jenkins Dev Overlay

Run:

```bash
kubectl apply -k overlays/dev
```

### Step 3: Verify Jenkins

Run:

```bash
kubectl get all -n jenkins-dev
kubectl get ingress -n jenkins-dev
```

Expected shape:

```text
NAME                           READY   STATUS    RESTARTS   AGE
pod/jenkins-xxxxxxxxxx-xxxxx   1/1     Running   0          Xm

NAME                    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)     AGE
service/jenkins         ClusterIP   10.96.xxx.xxx   <none>        8080/TCP    Xm
service/jenkins-jnlp4   ClusterIP   10.96.xxx.xxx   <none>        50000/TCP   Xm

NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/jenkins   1/1     1            1           Xm
```

If Jenkins is still starting, you may briefly see `503 Service Temporarily Unavailable`. That usually means the new pod is still initializing or applying plugins.

## Cloudflare Tunnel Setup

The tunnel script is:

- `scripts/setup_tunnel.sh`

It does the following:

1. checks whether `cloudflared` is installed
2. installs it with Homebrew if missing
3. runs `cloudflared tunnel login`
4. creates a tunnel called `kind-tunnel` if it does not already exist
5. creates `~/.cloudflared/config.yml`
6. creates the DNS routes for the Jenkins hostnames you want to expose
7. starts the tunnel

By default, it handles both:

- `nrsh13-jenkins-dev.nrsh13-hadoop.com`
- `nrsh13-jenkins-prod.nrsh13-hadoop.com`

The tunnel forwards traffic to the local Jenkins ingress using the correct host header.

### Run the Tunnel

From the repo root:

```bash
cd kind_k8s_cluster_setup
./scripts/setup_tunnel.sh
```

You can also run it for a single overlay only:

```bash
./scripts/setup_tunnel.sh dev
./scripts/setup_tunnel.sh prod
```

### Public Jenkins URL

Once the tunnel is running and Jenkins is ready:

- [https://nrsh13-jenkins-dev.nrsh13-hadoop.com](https://nrsh13-jenkins-dev.nrsh13-hadoop.com)
- [https://nrsh13-jenkins-prod.nrsh13-hadoop.com](https://nrsh13-jenkins-prod.nrsh13-hadoop.com)

### Important Note About Timing

If you redeploy Jenkins and test immediately:

- browser access through Cloudflare may temporarily show errors
- a short delay is normal while the new Jenkins pod becomes ready

If that happens, check:

```bash
kubectl get pods -n jenkins-dev
kubectl get all -n jenkins-dev
```

Wait until the Jenkins pod is `1/1 Running`.

## Useful Commands

### Cluster

```bash
kubectl cluster-info --context kind-dev-cluster
kubectl get nodes
kubectl get pods -A
```

### Controllers

```bash
kubectl get pods -n nrsh13
kubectl get svc -n nrsh13
kubectl get ingress -A
```

### Jenkins

```bash
kubectl get all -n jenkins-dev
kubectl logs -n jenkins-dev -l app=jenkins -c jenkins
kubectl logs -n jenkins-dev -l app=jenkins -c install-plugins
```

## Delete the Cluster

To tear everything down:

```bash
cd kind_k8s_cluster_setup
./scripts/delete-cluster.sh
```

This deletes the `kind` cluster named `dev-cluster`.

It does not remove:

- your Cloudflare tunnel
- your Cloudflare DNS setup
- your local `~/.cloudflared` files

## Summary

Use this order:

1. Make sure Cloudflare manages the domain via the nameserver change from Route 53.
2. Run `./scripts/k8s-cluster-setup.sh`
3. Run Jenkins sealed-secret generation
4. Run `kubectl apply -k overlays/dev`
5. Wait for Jenkins to become ready
6. Run `./scripts/setup_tunnel.sh`
7. Open `https://nrsh13-jenkins-dev.nrsh13-hadoop.com`
