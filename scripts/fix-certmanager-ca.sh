#!/usr/bin/env bash
# Workaround seen with microsoft.certmanagement + pipelinecontroller 1.7.0 on K3s:
# the '<ca>-current' secrets and rotation label were never created, so the
# ClusterIssuers/trust bundles stayed not-ready and the pipeline pod hung in Init.
# Lab-only: these copies do NOT rotate.
set -euo pipefail
for s in arc-amp-root-ca arc-amp-client-root-ca; do
  kubectl -n cert-manager get secret "$s" -o json \
   | jq --arg n "$s-current" --arg s "$s" '{apiVersion,kind,type,data,metadata:{name:$n,namespace:"cert-manager",labels:{"microsoft-certmanagement.clusterextensions.azure.com/ac-rotation-active":$s}}}' \
   | kubectl apply -f -
done
kubectl -n amp delete pod -l pipeline --wait=false
