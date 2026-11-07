#!/usr/bin/env bash
# Secrets some v2.1 services expect but cluster-configs does not create.
# Run after cluster-configs is deployed (it reuses values cluster-configs already created).
set -euo pipefail
ES_PASS=$(kubectl -n egov get secret elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d)
S3_KEY=$(kubectl -n egov get secret egov-filestore -o jsonpath='{.data.awskey}' | base64 -d)
S3_SECRET=$(kubectl -n egov get secret egov-filestore -o jsonpath='{.data.awssecretkey}' | base64 -d)

# Elasticsearch credentials used by egov-indexer and health-muster-roll
kubectl -n egov create secret generic elastic \
  --from-literal=username=elastic --from-literal=password="$ES_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
# S3 credentials used by referralmanagement (in-cluster MinIO)
kubectl -n egov create secret generic egov-s3 \
  --from-literal=access-key="$S3_KEY" --from-literal=secret-key="$S3_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
