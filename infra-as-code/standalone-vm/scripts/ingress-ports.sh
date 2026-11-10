#!/bin/sh
# Forwards host ports 80/443 on the public interface to the minikube ingress NodePorts.
# Uses DNAT rather than a proxy so ingress-nginx sees real client IPs (the gateway rate-limits per IP).
# Idempotent; run as root at boot after docker (see README, 6.1).
#   IF   public interface (default: interface of the default route)
#   NODE minikube IP (default: 192.168.49.2, the docker driver default; check with `minikube ip`)
set -e
IF=${IF:-$(ip route show default | awk '{print $5; exit}')}
NODE=${NODE:-192.168.49.2}
rule() { t=$1; c=$2; shift 2; iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -I "$c" "$@"; }
rule nat PREROUTING -i "$IF" -p tcp --dport 80  -j DNAT --to-destination "$NODE:30080"
rule nat PREROUTING -i "$IF" -p tcp --dport 443 -j DNAT --to-destination "$NODE:30443"
rule filter DOCKER-USER -i "$IF" -d "$NODE" -p tcp -m multiport --dports 30080,30443 -j ACCEPT
