#!/usr/bin/env bash
# Секреты окружения → Vault. В Kubernetes их переносит External Secrets (ExternalSecret рядом с потребителем),
# в git их нет. Повторный запуск безопасен: что уже есть в Vault, не меняется (кроме значений из .env).
#   secret/payments   ключи сервисов из payments-local/.env + пароль базы (создаётся один раз)
#   secret/grafana    пароль admin Grafana (создаётся один раз)
#   secret/keycloak   пароли Keycloak: admin, его база, демо-пользователь (создаются один раз)
# Затем — пароли в самой Postgres (ALTER USER/CREATE ROLE), чтобы база совпадала с Vault.
# Нужен настроенный Vault: scripts/vault-init.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/vault-lib.sh
. scripts/vault-lib.sh

ENV_FILE=../payments-local/.env
[ -f "$ENV_FILE" ] || { echo "Нет $ENV_FILE — см. payments-local/.env.example" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
for name in QUOTE_SECRET CARD_HMAC_KEY CARD_ENCRYPTION_KEY; do
  [ -n "${!name:-}" ] || { echo "В $ENV_FILE не задан $name" >&2; exit 1; }
done

# Случайный пароль: только буквы и цифры — без кавычек и спецсимволов в SQL и URL
new_password() { openssl rand -hex 20; }
# field <JSON> <ключ> — значение ключа или пустая строка
field() { [[ -n $1 ]] || return 0; jq -r --arg k "$2" '.[$k] // empty' <<<"$1"; }

# --- secret/payments ---
current=$(vault_read payments)
db_password=$(field "$current" DB_PASSWORD)
db_password=${db_password:-$(new_password)}
vault_write payments "$(jq -n \
  --arg q "$QUOTE_SECRET" --arg h "$CARD_HMAC_KEY" --arg e "$CARD_ENCRYPTION_KEY" --arg d "$db_password" \
  '{QUOTE_SECRET: $q, CARD_HMAC_KEY: $h, CARD_ENCRYPTION_KEY: $e, DB_PASSWORD: $d}')"
echo "Vault: secret/payments"

# --- secret/grafana --- (если секрет уже был в кластере до Vault — переносим тот же пароль)
current=$(vault_read grafana)
if [[ -z $(field "$current" admin-password) ]]; then
  password=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
  vault_write grafana "$(jq -n --arg p "${password:-$(new_password)}" '{"admin-user": "admin", "admin-password": $p}')"
  echo "Vault: secret/grafana"
fi

# --- secret/keycloak ---
current=$(vault_read keycloak)
if [[ -z $(field "$current" admin-password) ]]; then
  vault_write keycloak "$(jq -n --arg a "$(new_password)" --arg d "$(new_password)" --arg u "$(new_password)" \
    '{"admin-password": $a, "db-password": $d, "demo-password": $u}')"
  echo "Vault: secret/keycloak"
fi
keycloak_db_password=$(field "$(vault_read keycloak)" db-password)

# --- Пароли в Postgres ---
# Сначала ждём, пока External Secrets положит новый пароль в payments-secrets: иначе сервисы, которые
# перезапустятся в этот момент, придут со старым
echo "Жду синхронизации payments-secrets…"
for _ in $(seq 60); do
  synced=$(kubectl -n payments get secret payments-secrets -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d || true)
  [[ $synced == "$db_password" ]] && break
  kubectl -n payments annotate externalsecret payments-secrets force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  sleep 5
done
[[ $synced == "$db_password" ]] || { echo "payments-secrets не обновился — проверьте: kubectl -n payments get externalsecret" >&2; exit 1; }

# SQL — через stdin (пароли не попадают в аргументы команд). Внутри пода psql входит без пароля (локальный сокет)
kubectl -n payments exec -i postgres-0 -- psql -q -U payments -d payments -v ON_ERROR_STOP=1 <<SQL
ALTER ROLE payments WITH PASSWORD '$db_password';
-- Keycloak: своя роль и своя база (не схема в payments): у него свои миграции и ему не нужен доступ к данным сервисов
SELECT 'CREATE ROLE keycloak LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak')\gexec
ALTER ROLE keycloak WITH LOGIN PASSWORD '$keycloak_db_password';
SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
SQL
echo "Postgres: пароли payments и keycloak совпадают с Vault"
echo "Если пароль базы только что появился или сменился — перезапустить сервисы:"
echo "  kubectl -n payments rollout restart deployment"
