#!/usr/bin/env bash
# Секреты в кластере: сервисов (namespace payments, секрет payments-secrets) — из payments-local/.env;
# пароль admin Grafana (namespace monitoring, секрет grafana-admin) — создаётся один раз случайным.
# В git секреты не кладём; поменяли .env — запустить снова и перезапустить сервисы:
#   kubectl -n payments rollout restart deployment
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=../payments-local/.env
[ -f "$ENV_FILE" ] || { echo "Нет $ENV_FILE — см. payments-local/.env.example" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

for name in QUOTE_SECRET CARD_HMAC_KEY CARD_ENCRYPTION_KEY; do
  [ -n "${!name:-}" ] || { echo "В $ENV_FILE не задан $name" >&2; exit 1; }
done

kubectl create namespace payments --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n payments create secret generic payments-secrets \
  --from-literal=QUOTE_SECRET="$QUOTE_SECRET" \
  --from-literal=CARD_HMAC_KEY="$CARD_HMAC_KEY" \
  --from-literal=CARD_ENCRYPTION_KEY="$CARD_ENCRYPTION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "Секрет payments-secrets обновлён"

# Пароль Grafana: создать, только если его ещё нет (повторный запуск не меняет пароль).
# Посмотреть: kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 18)" >/dev/null
  echo "Секрет grafana-admin создан"
fi
