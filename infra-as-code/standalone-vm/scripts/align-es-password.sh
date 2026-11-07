#!/usr/bin/env bash
# The Elasticsearch chart generates a random `elastic` password on every render, while
# cluster-configs copies the password from the secrets file into the `egov` namespace for the
# HCM services. This makes Elasticsearch, its secrets and the services agree on the secrets-file
# password. Run after every deploy of elasticsearch-master / elasticsearch-data.
set -euo pipefail
NS=es-cluster
POD=elasticsearch-master-0
WANT=$(kubectl -n egov get secret elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d)
# wait until the Elasticsearch process answers (not "ready": readiness uses the password)
until kubectl -n $NS exec $POD -c elasticsearch -- curl -sk -o /dev/null https://localhost:9200/ 2>/dev/null; do sleep 5; done
code() { kubectl -n $NS exec $POD -c elasticsearch -- curl -sk -o /dev/null -w '%{http_code}' -u "elastic:$1" https://localhost:9200/; }

if [ "$(code "$WANT")" != "200" ]; then
  CUR=$(kubectl -n $NS get secret elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d)
  [ "$(code "$CUR")" = "200" ] || { echo "Neither password works; check Elasticsearch" >&2; exit 1; }
  kubectl -n $NS exec $POD -c elasticsearch -- curl -sk -u "elastic:$CUR" -XPOST \
    https://localhost:9200/_security/user/elastic/_password -H 'Content-Type: application/json' \
    -d "{\"password\":\"$WANT\"}" >/dev/null
  echo "elastic password changed to the secrets-file value"
fi

CHANGED=0
for s in elasticsearch-master-credentials elasticsearch-data-credentials; do
  if [ "$(kubectl -n $NS get secret $s -o jsonpath='{.data.password}' | base64 -d)" != "$WANT" ]; then
    kubectl -n $NS patch secret $s -p "{\"data\":{\"password\":\"$(printf %s "$WANT" | base64 -w0)\"}}"
    CHANGED=1
  fi
done
if [ "$CHANGED" = 1 ]; then
  # pods read the password from env at start (readiness probe); restart them
  kubectl -n $NS delete pod elasticsearch-master-0 elasticsearch-data-0
  kubectl -n $NS wait --for=condition=ready pod/elasticsearch-master-0 pod/elasticsearch-data-0 --timeout=600s
fi
echo "Elasticsearch password aligned"
