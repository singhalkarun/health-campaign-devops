#!/usr/bin/env bash
# The kafka-kraft chart runs 3 controllers with REQUIRED pod anti-affinity (one per node), so only
# one can start on a single VM. Relax it to "preferred" so all 3 run on the one node.
# Run after every deploy of kafka-kraft.
set -euo pipefail
NS=kafka-kraft
STS=release-name-kafka-controller
SEL=$(kubectl -n $NS get sts $STS -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector}')
if [ -n "$SEL" ]; then
  kubectl -n $NS patch sts $STS --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/affinity/podAntiAffinity\",\"value\":{\"preferredDuringSchedulingIgnoredDuringExecution\":[{\"weight\":1,\"podAffinityTerm\":{\"labelSelector\":$SEL,\"topologyKey\":\"kubernetes.io/hostname\"}}]}}]"
  # anti-affinity is symmetric: pods created from the old template must go too
  kubectl -n $NS delete pod -l app.kubernetes.io/component=controller-eligible --wait=false
fi
kubectl -n $NS rollout status sts/$STS --timeout=600s
