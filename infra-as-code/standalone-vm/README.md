# HCM on a standalone VM (minikube)

This guide runs a complete HCM (Health Campaign Management) instance on **one Linux VM** using minikube.
It is meant for demos, analysis and development where high availability is not needed.

It does **not** repeat the official installation steps. For every core step, follow the official
[Deploy HCM](https://docs.digit.org/health/deploy/installation/production-setup/deploy-hcm) documentation;
this guide only lists **what is different on a standalone VM**.

Everything (databases, search, queues, file storage, frontend configs) runs **inside the VM**. The only outside dependencies are:

- container images from their official registries (Docker Hub `egovio/*`, `registry.k8s.io`, `quay.io/jetstack`, `docker.elastic.co`), pulled once and cached on the VM
- the public `health-campaign-config` GitHub repo, read over HTTPS by git-sync
- one-time downloads: the official HCM seed data dump and eGov's public frontend `globalConfigs` files
- in the browser only: the frontend images load the `xlsx` library from unpkg.com

> Status: validated end to end for HCM v2.1 (branch `azure-install-hcm-demo-v2.1`) on Ubuntu 24.04, minikube v1.39, Kubernetes v1.31.

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
| Step 3: deployment config | Use the ready-made [`config-as-code/environments/hcm-standalone-vm.yaml`](../../config-as-code/environments/hcm-standalone-vm.yaml) (derived from `hcm-demo-azure.yaml`, see [4](#4-self-contained-setup)). Its domain is the private placeholder `hcm.internal` (avoid `.local`, which macOS reserves for mDNS); if you change it, replace it everywhere in the file. No SMS / payment / GMap provider is needed for the stack to start |
| Step 4: secrets | Copy [`hcm-standalone-vm-secrets.yaml.template`](../../config-as-code/environments/hcm-standalone-vm-secrets.yaml.template) to `hcm-standalone-vm-secrets.yaml` and fill in newly generated values. A plain-text file readable only by its owner (`chmod 600`) is acceptable for a single VM, as the docs allow for demos; never commit it. Remove (rename) `config-as-code/.sops.yaml` and `config-as-code/helm/.sops.yaml`, otherwise the deployer tries to decrypt the file with eGov's key. Back up the `egov-enc-service` master password/salt/IV: data encrypted with them cannot be read without them |
| Step 5: repos | No forks or SSH keys needed: `global.gitSync.ssh: false` makes git-sync read the public eGov config repo over **HTTPS**. Config branch: `HCM-v2.1-DEMO`. MDMS is DB-backed (`mdms-v2`) in v2.1, so the MDMS repo is not used |
| Step 6: environment values | Already done in the environment file, see [4](#4-self-contained-setup) |
| Step 7: storage | MinIO inside the cluster instead of a cloud bucket (see [4](#4-self-contained-setup)) |

## 4. Self-contained setup

What `hcm-standalone-vm.yaml` and this folder change compared with `hcm-demo-azure.yaml`, so that nothing points at external infrastructure:

| Area | Change |
|---|---|
| Database | Postgres 14 inside the cluster ([`manifests/postgres.yaml`](manifests/postgres.yaml)); `db-host` = `postgres.backbone.svc.cluster.local` |
| File storage | MinIO inside the cluster ([`manifests/minio.yaml`](manifests/minio.yaml), image `egovio/minio` because MinIO no longer publishes public images). `egov-filestore` runs in S3 mode against it (its chart is hardwired to Azure Blob, so the env file overrides its `env` block) |
| Elasticsearch | 1 master + 1 data node on dynamically provisioned `standard` volumes (chart change: static PVs only when a cloud disk is configured). Master heap 1 GB |
| Kafka | Chart unchanged (3 KRaft controllers); [`scripts/kafka-single-node.sh`](scripts/kafka-single-node.sh) relaxes its required anti-affinity so all 3 fit on one node |
| TLS | `selfsigned` cert-manager issuer ([`manifests/selfsigned-issuer.yaml`](manifests/selfsigned-issuer.yaml)) instead of Let's Encrypt |
| Frontend configs | [`assets/deploy-assets.sh`](assets/deploy-assets.sh) serves the `globalConfigs*.js` files at `/hcm-assets/` (downloaded once from eGov's public bucket; eGov's Google keys removed). Analytics / telemetry scripts removed |
| Replicas | 1 replica everywhere |
| Git | `global.gitSync.ssh: false` (chart change: `GIT_SYNC_SSH` follows this setting, default stays `true`) |
| Fixes needed to render / start on this branch | `hpa.enabled: false` for charts without HPA defaults; `project-factory` values indentation and `individual-referral` `Chart.yaml` fixed; missing values for `transformer`, `resource-generator`, `auth-proxy`, `egov-localization` (`redis-downsync-host`), frontend `namespace`; tenant overrides for `inbox` and `individual-referral`; secrets `elastic` and `egov-s3` ([`scripts/extra-secrets.sh`](scripts/extra-secrets.sh)) |

Services deployed: all services with an image in the env file, plus `census-service`, `plan-service`, `resource-generator`, `auth-proxy`. Not deployed: legacy `egov-mdms-service` (v2.1 routes MDMS calls to `mdms-v2`), `hcm-moz-impl` (country-specific), `airflow-trigger` (needs Airflow), `egov-malware-detection` (scanning is off), `egov-notification-push` (needs a Firebase key).

## 5. Deploy

Follow [2. Deploy Application](https://docs.digit.org/health/deploy/installation/production-setup/deploy-hcm/2.-deploy-application) with these differences.

- Install **Go 1.13.3** as the docs say (it builds the deployer fine).
- Do **not** run `go run digit_installer.go`: on this branch it deploys the **v2.0** service list with v2.0 image tags (overriding v2.1) and the env `egov-demo`, and its module names do not match (redis, ingress, gateway would be skipped). Call the deployer directly instead; services given without a tag get their **v2.1 tag from the environment file**.
- Deploy in two phases: the ingress admission webhook must be running before anything with an Ingress is applied.

```bash
cd health-campaign-devops/deploy-as-code/deployer
ENV=hcm-standalone-vm
SA=../../infra-as-code/standalone-vm

# Phase A: cluster configs + backbone
go run main.go deploy -c -e $ENV cert-manager,ingress-nginx,redis,kafka-kraft,elasticsearch-master,elasticsearch-data
kubectl -n egov rollout status deploy/ingress-nginx-controller
$SA/scripts/kafka-single-node.sh
$SA/scripts/align-es-password.sh            # ES chart makes a random password; use the secrets-file one
go run main.go deploy -e $ENV kibana
kubectl apply -f $SA/manifests/postgres.yaml -f $SA/manifests/minio.yaml -f $SA/manifests/selfsigned-issuer.yaml
kubectl -n backbone rollout status sts/postgres && kubectl -n backbone wait --for=condition=complete job/minio-create-bucket
$SA/scripts/extra-secrets.sh

# Phase B: applications, one at a time (a failure does not stop the rest)
CORE=egov-accesscontrol,egov-enc-service,egov-localization,egov-idgen,egov-filestore,egov-indexer,egov-notification-mail,egov-notification-sms,egov-otp,egov-persister,egov-url-shortening,egov-user,egov-user-event,user-otp,egov-workflow-v2,audit-service,beneficiary-idgen,error-handler,playground,mdms-v2,boundary-service,pdf-service,gateway,egov-hrms,inbox,dashboard-analytics,dashboard-ingest
MICROPLAN=egovio/census-service:v1.0.1-ddae2629dc-105,egovio/plan-service:v1.0.2-0ea4104b4b-303,egovio/resource-generator:v1.0.2-b8bfac27c7-142,egovio/auth-proxy:auth-proxy-user-fail-fix-2-a92d71909d-41
HEALTH=facility,product,individual,transformer,stock,household,project,referralmanagement,service-request,health-attendance,health-expense,health-expense-calculator,health-muster-roll,pgr-services,project-factory,boundary-management,excel-ingestion,worker-registry,health-notification-service,household-referral,individual-referral
FRONTEND=digit-ui,microplan-ui,payments-ui,workbench-ui,console,core-ui,dashboard-ui,dss-dashboard
for s in $(echo $CORE,$MICROPLAN,$HEALTH,$FRONTEND | tr , ' '); do
  go run main.go deploy -e $ENV "$s" > "/tmp/deploy-${s##*/}.log" 2>&1 && echo "OK $s" || echo "FAIL $s"
done
$SA/assets/deploy-assets.sh hcm.internal
```

Notes:

- First start takes 10–20 minutes (about 60 JVMs start at once); some pods restart a few times until their dependencies are up.
- Re-deploying a non-eGov chart (e.g. `kibana`): delete its Deployment and pre-install Job first. The deployer copies the running image tag into `image.tag`, which breaks charts whose `image` is a plain string, and Jobs are immutable.
- After re-deploying `elasticsearch-*` run `scripts/align-es-password.sh`; after re-deploying `kafka-kraft` run `scripts/kafka-single-node.sh`.

### 5.1 System data

Follow [Setup System Data](https://docs.digit.org/health/deploy/installation/setup-system-data) with these differences:

- The official dump `seed_data_dump_2_1.sql` is for tenant `mz` in schema `public`. This environment (like `hcm-demo-azure`) is a central instance with tenant `demo` and schema `demo`. Re-target the dump before loading it:
  `python3 -I scripts/retarget-seed.py seed_data_dump_2_1.sql seed_demo.sql demo demo`
  then load `seed_demo.sql` from the playground pod as the docs show (DB host `postgres.backbone.svc.cluster.local`, credentials from your secrets file).
- In the workflow and superuser requests, use tenant `demo` instead of `mz`. Choose your own superuser name and password.
- After the first start, set `egov-internal-microservice-user-uuid` in the env file to the uuid of the `INTERNAL_MICROSERVICE_ROLE` user that the services create, re-run cluster configs (`go run main.go deploy -c -e $ENV inbox`) and restart `inbox`:
  `select u.uuid from demo.eg_user u join demo.eg_userrole_v1 r on r.user_id=u.id where r.role_code='INTERNAL_MICROSERVICE_ROLE';`
- Localization messages are not part of the published seed (the UI shows message keys without them). [`scripts/load-localization.py`](scripts/load-localization.py) copies them from eGov's public demo (tenants `mz`/`demo`, locales `en_MZ`, `pt_MZ`, `fr_MZ`, `en_DEMO`) into your tenant, about 240k messages:
  ```bash
  python3 -I $SA/scripts/load-localization.py download localization.json
  HCM_USER=<superuser> HCM_PASSWORD=<password> python3 -I $SA/scripts/load-localization.py upload localization.json https://<domain> demo
  ```
  The script de-duplicates codes the service treats as equal (trimmed, case-insensitive) and sends one module per request, because the upsert API rejects a request where the same code appears twice.

## 6. Access

The ingress controller's Service is `LoadBalancer`, which stays pending on minikube. Pin its NodePorts once:

```bash
kubectl -n egov patch svc ingress-nginx-controller --type=json -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080},{"op":"replace","path":"/spec/ports/1/nodePort","value":30443}]'
```

From your laptop (macOS allows non-root processes to listen on 443):

```bash
ssh -N -L 443:$(ssh <vm> minikube ip):30443 <vm>
echo "127.0.0.1 hcm.internal" | sudo tee -a /etc/hosts
```

Open `https://hcm.internal/console` and accept the self-signed certificate warning. Log in with the superuser created in 5.1 (city/tenant `demo`).

### 6.1 Public domain (optional)

To serve HCM on a real domain with a Let's Encrypt certificate instead of the tunnel:

1. Give the VM a static public IP and point an `A` record for your domain at it.
2. Open inbound TCP 80 and 443 to everyone (Let's Encrypt validates over port 80; the VM's own services also call the domain).
3. Forward host ports 80/443 to the ingress NodePorts on every boot with [`scripts/ingress-ports.sh`](scripts/ingress-ports.sh):
   ```bash
   sudo install -m 755 $SA/scripts/ingress-ports.sh /usr/local/sbin/hcm-ingress-ports.sh
   sudo tee /etc/systemd/system/hcm-ingress-ports.service >/dev/null <<'UNIT'
   [Unit]
   Description=Forward host 80/443 to minikube ingress NodePorts
   After=docker.service
   PartOf=docker.service
   [Service]
   Type=oneshot
   RemainAfterExit=yes
   ExecStart=/usr/local/sbin/hcm-ingress-ports.sh
   [Install]
   WantedBy=multi-user.target docker.service
   UNIT
   sudo systemctl daemon-reload && sudo systemctl enable --now hcm-ingress-ports
   ```
4. In the env file, replace `hcm.internal` with your domain everywhere and set both `cert-issuer` values to `letsencrypt-prod`.
5. Re-deploy cluster configs, `ingress-nginx` and every application (the same commands as in section 5), re-run `assets/deploy-assets.sh <domain>`, then `kubectl -n egov rollout restart deploy` so the services read the new domain.

cert-manager waits until its own check of `http://<domain>/.well-known/acme-challenge/...` succeeds before it contacts Let's Encrypt, so you can re-deploy before opening the ports.
