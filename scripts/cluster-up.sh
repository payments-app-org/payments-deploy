#!/usr/bin/env bash
# Поднять окружение с нуля: кластер k3d → Argo CD → секреты → приложения из git.
# Повторный запуск безопасен: что уже есть, не пересоздаётся. Кластер остановлен (k3d cluster stop) — запускает.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=payments
ARGOCD_CHART_VERSION=10.13.1 # Argo CD v3.6.1

if ! k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  k3d cluster create --config cluster/k3d.yaml
else
  k3d cluster start "$CLUSTER"
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null

helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values argocd/values.yaml --wait

scripts/secrets.sh
kubectl apply -f argocd/root.yaml

echo
echo "Готово. Argo CD разворачивает приложения (первый раз — несколько минут):"
echo "  kubectl get pods -n payments"
echo "  http://argocd.localhost — логин admin, пароль:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo "  http://payments.localhost — приложение"
