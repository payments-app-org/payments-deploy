#!/usr/bin/env bash
# Поднять окружение с нуля: кластер k3d → Argo CD → секреты → приложения окружения из git.
# Повторный запуск безопасен: что уже есть, не пересоздаётся. Кластер остановлен (k3d cluster stop) — запускает.
# Окружение — первый аргумент (по умолчанию prod): берётся envs/<окружение>/
set -euo pipefail
cd "$(dirname "$0")/.."

ENV=${1:-prod}
CLUSTER=payments
ARGOCD_CHART_VERSION=10.13.1 # Argo CD v3.6.1; та же версия — в envs/$ENV/apps/platform/argocd.yaml

[[ -d "envs/$ENV" ]] || { echo "Нет окружения envs/$ENV" >&2; exit 1; }

if ! k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  k3d cluster create --config cluster/k3d.yaml
else
  k3d cluster start "$CLUSTER"
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null

# Первая установка Argo CD. Маршрут (HTTPRoute) пока выключен: типов Gateway API в кластере ещё нет —
# их поставит сам Argo CD (envs/$ENV/apps/platform/gateway-api.yaml), потом включит и маршрут
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values platform/argocd/values.yaml --values "envs/$ENV/platform/argocd.yaml" \
  --set server.httproute.enabled=false --wait

kubectl apply -f "envs/$ENV/root.yaml"

# Секреты: Vault ставит Argo CD (первым, sync-wave -1). Дальше — инициализация Vault и запись секретов в него;
# в Kubernetes их перенесёт External Secrets. Сервисы ждут свои секреты и стартуют, когда те появятся
scripts/vault-init.sh
echo "Жду Postgres (пароли базы)…"
until kubectl -n payments get pod postgres-0 >/dev/null 2>&1; do sleep 5; done
kubectl -n payments wait --for=condition=Ready pod/postgres-0 --timeout=15m
scripts/secrets.sh

echo
echo "Готово. Argo CD разворачивает окружение $ENV (первый раз — несколько минут):"
echo "  kubectl get applications -n argocd"
echo "  kubectl get pods -n payments"
echo "  http://argocd.localhost — логин admin, пароль:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo "  http://payments.localhost — приложение, http://traefik.localhost/dashboard/ — маршруты Traefik"
echo "  http://vault.localhost — Vault, токен: kubectl -n vault get secret vault-unseal -o jsonpath='{.data.root-token}' | base64 -d; echo"
