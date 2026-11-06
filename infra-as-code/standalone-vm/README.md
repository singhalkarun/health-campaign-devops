# HCM on a standalone VM (minikube)

This guide runs a complete HCM (Health Campaign Management) instance on **one Linux VM** using minikube.
It is meant for demos, analysis and development where high availability is not needed.

It does **not** repeat the official installation steps. For every core step, follow the official
[Deploy HCM](https://docs.digit.org/health/deploy/installation/production-setup/deploy-hcm) documentation;
this guide only lists **what is different on a standalone VM**.

Everything (databases, search, queues, file storage) runs **inside the VM**. The only outside dependencies are:

- container images from Docker Hub (`egovio/*`), pulled once and cached on the VM
- the public `health-campaign-config` / `health-campaign-mdms` GitHub repos, read over HTTPS by git-sync

> Status: work in progress. Sections marked **TODO** are still being validated.

## 1. VM requirements

| Item | Value | Why |
|---|---|---|
| CPU architecture | **x86_64** | Most `egovio/*` images are published for amd64 only |
| vCPU / RAM | **16 vCPU / 128 GB** (e.g. AWS `r6i.4xlarge`) | ~80 services at 1 replica need ~57 GB in memory limits, plus Elasticsearch, Kafka, Postgres, Redis and Kubernetes itself. 64 GB is not enough |
| Disk | **500 GB** SSD | Elasticsearch, Kafka, Postgres volumes and container images |
| OS | Ubuntu 24.04 LTS | Tested |
| Inbound network | SSH only | The app is reached through an SSH tunnel (see [Access](#5-access)) |

## 2. Cluster setup (minikube)

The official docs assume a Kubernetes cluster already exists. On a standalone VM, create it with minikube.

### 2.1 Tools

```bash
sudo apt-get update
sudo apt-get install -y docker.io conntrack jq unzip curl
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"     # log out and back in afterwards

K8S_VERSION=v1.31.14                # HCM's reference infra uses Kubernetes 1.31
sudo curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
sudo chmod +x /usr/local/bin/kubectl
sudo curl -fsSLo /usr/local/bin/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo chmod +x /usr/local/bin/minikube
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 2.2 Kernel settings

Elasticsearch does not start without `vm.max_map_count`, and ~100 pods on one node need more inotify headroom.

```bash
sudo tee /etc/sysctl.d/99-hcm.conf <<'EOF'
vm.max_map_count=262144
fs.inotify.max_user_watches=1048576
fs.inotify.max_user_instances=8192
fs.file-max=2097152
EOF
sudo sysctl --system
```

### 2.3 Start the cluster

```bash
minikube start --driver=docker --kubernetes-version=v1.31.14 \
  --cpus=14 --memory=112g \
  --extra-config=kubelet.max-pods=250
```

- `--cpus` / `--memory`: leave ~2 vCPU and ~16 GB for the OS.
- `kubelet.max-pods=250`: Kubernetes allows only **110 pods per node** by default; HCM plus its backbone services gets close to or over that.
- Do **not** enable the minikube `ingress` addon. The HCM deployment installs its own nginx ingress controller.
- The default storage class on minikube is **`standard`** (the reference environment files use `gp3`).

### 2.4 Start on boot, stop cleanly on shutdown

Useful when the VM is stopped at night to save cost.

```bash
sudo tee /etc/systemd/system/minikube.service <<EOF
[Unit]
Description=minikube cluster for HCM
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$USER
Environment=HOME=$HOME
ExecStart=/usr/local/bin/minikube start
ExecStop=/usr/local/bin/minikube stop
TimeoutStartSec=900
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now minikube.service
```

Check: `kubectl get nodes` shows `minikube` as `Ready`, also after a reboot.

## 3. Prepare deployment configuration

Follow [1. Prepare Deployment Configuration](https://docs.digit.org/health/deploy/installation/production-setup/deploy-hcm/1.-prepare-deployment-configuration).
Differences on a standalone VM, by step:

| Docs step | Standalone VM difference |
|---|---|
| Step 1: clone | Clone on the VM. Use branch `azure-install-hcm-demo-v2.1` for HCM v2.1 |
| Step 2: open editor | The VM is headless. Use VS Code Remote-SSH, or edit with any terminal editor |
| Step 3: deployment config | Without a real domain, use a private placeholder such as `hcm.internal` (avoid `.local`, which macOS reserves for mDNS). No SMS / payment / GMap provider is required for the stack to start; leave their placeholders |
| Step 4: secrets | The sample secrets file is sops-encrypted with a key you do not have. Write your own secrets file with newly generated values (template: **TODO**). For a single VM, a plain-text file readable only by its owner (`chmod 600`) is acceptable, as the docs allow for demos; never commit it. Keep a backup of the `egov-enc-service` master password/salt/IV: data encrypted with them cannot be read without them |
| Step 5: repos | No forks or SSH keys needed: git-sync reads the public eGov repos over **HTTPS** (**TODO**: setting in this PR). Config repo branch: `HCM-v2.1-DEMO` |
| Step 6: environment values | See [4. Self-contained setup](#4-self-contained-setup) |
| Step 7: storage | MinIO inside the cluster instead of a cloud bucket (**TODO**) |

## 4. Self-contained setup

**TODO.** Changes so that nothing points at external infrastructure:

- [ ] 1 replica per service
- [ ] Postgres inside the cluster
- [ ] Elasticsearch on local volumes, storage class `standard`
- [ ] MinIO for filestore and public assets
- [ ] Frontend `globalConfigs` served from the VM
- [ ] Self-signed TLS certificate
- [ ] Deployment set selection (skip the legacy git-based `egov-mdms-service`; v2.1 routes MDMS calls to the DB-backed `mdms-v2`)

## 5. Access

**TODO.** SSH tunnel to the ingress and a hosts-file entry for the placeholder domain.

## 6. Deploy

Follow [2. Deploy Application](https://docs.digit.org/health/deploy/installation/production-setup/deploy-hcm/2.-deploy-application) (**TODO**: standalone notes).
