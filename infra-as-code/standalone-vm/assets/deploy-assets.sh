#!/usr/bin/env bash
# Serves the frontend globalConfigs*.js files from the VM instead of eGov's S3 buckets.
# It downloads eGov's published demo configs once, removes eGov-specific keys/URLs and
# serves them at https://<domain>/hcm-assets/ through an nginx pod.
#
# Usage: ./deploy-assets.sh <domain>        e.g. ./deploy-assets.sh hcm.internal
set -euo pipefail
DOMAIN="${1:?usage: $0 <domain>}"
NS=egov
SRC=https://hcm-demo-assets.s3.ap-south-1.amazonaws.com/demo
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for f in globalConfigs globalConfigsConsoleDemo globalConfigsWorkbenchDemo globalConfigsDashboardDemo \
         globalConfigsMicroplanDemo globalConfigsCoreUIDemo globalConfigsPayments; do
  curl -fsSL -o "$WORK/$f.js" "$SRC/$f.js"
done
curl -fsSL -o "$WORK/globalConfigs-employee.js" https://egov-health-demo-assets.s3.ap-south-1.amazonaws.com/globalConfigs.js
curl -fsSL -o "$WORK/digit-footer.png"    https://egov-uat-assets.s3.ap-south-1.amazonaws.com/digit-footer.png
curl -fsSL -o "$WORK/digit-footer-bw.png" https://egov-uat-assets.s3.ap-south-1.amazonaws.com/digit-footer-bw.png

for js in "$WORK"/*.js; do
  sed -i -E \
    -e 's#(gmaps_api_key *= *)"[^"]*"#\1""#' \
    -e 's#(googleClientId *= *)"[^"]*"#\1""#' \
    -e 's#https://(s3\.ap-south-1\.amazonaws\.com/egov-uat-assets|egov-uat-assets\.s3\.ap-south-1\.amazonaws\.com|unified-dev\.digit\.org/egov-dev-assets)/digit-footer#/hcm-assets/digit-footer#g' \
    -e "s#https://health-demo(-kibana)?\.digit\.org#https://${DOMAIN}#g" \
    "$js"
done

kubectl -n "$NS" create configmap hcm-assets --from-file="$WORK" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hcm-assets
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: hcm-assets}
  template:
    metadata:
      labels: {app: hcm-assets}
      annotations:
        configmap-checksum: "$(kubectl -n "$NS" get configmap hcm-assets -o jsonpath='{.metadata.resourceVersion}')"
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{containerPort: 80}]
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {memory: 64Mi}
          volumeMounts:
            - {name: assets, mountPath: /usr/share/nginx/html/hcm-assets}
      volumes:
        - name: assets
          configMap: {name: hcm-assets}
---
apiVersion: v1
kind: Service
metadata:
  name: hcm-assets
  namespace: ${NS}
spec:
  selector: {app: hcm-assets}
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hcm-assets
  namespace: ${NS}
spec:
  ingressClassName: nginx
  tls:
    - hosts: [${DOMAIN}]
      secretName: ${DOMAIN}-tls-certs
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /hcm-assets
            pathType: Prefix
            backend:
              service:
                name: hcm-assets
                port: {number: 80}
YAML
echo "Assets served at https://${DOMAIN}/hcm-assets/"
