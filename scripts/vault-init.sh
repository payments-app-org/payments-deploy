#!/usr/bin/env bash
# Первый запуск Vault в кластере и его настройка. Повторный запуск безопасен: сделанное пропускается.
#   1. Инициализация: Vault создаёт ключ шифрования и root-токен. Ключ распечатывания и токен — в секрет
#      vault/vault-unseal (по нему Vault распечатывается после перезапуска, см. platform/vault/values.yaml)
#   2. Движок KV v2 по пути secret/ — хранилище секретов с версиями
#   3. Вход для External Secrets: Kubernetes-аутентификация и роль external-secrets — только чтение secret/*
# В проде это делают Terraform (провайдер vault) или аналог; здесь — скрипт, чтобы был виден каждый шаг
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/vault-lib.sh
. scripts/vault-lib.sh

echo "Жду под vault-0…"
until kubectl -n "$VAULT_NS" get pod vault-0 -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].started}' 2>/dev/null | grep -q true; do
  sleep 5
done

status=$(kubectl -n "$VAULT_NS" exec vault-0 -c vault -- vault status -format=json 2>/dev/null || true)

# 1. Инициализация (один раз за жизнь хранилища). Одна часть ключа вместо пяти (Shamir): на стенде ключ
#    всё равно лежит рядом. В проде части раздают разным людям или включают auto-unseal через KMS
if [[ $(jq -r '.initialized' <<<"$status") != true ]]; then
  init=$(kubectl -n "$VAULT_NS" exec vault-0 -c vault -- vault operator init -key-shares=1 -key-threshold=1 -format=json)
  kubectl -n "$VAULT_NS" create secret generic vault-unseal \
    --from-literal=unseal-key="$(jq -r '.unseal_keys_b64[0]' <<<"$init")" \
    --from-literal=root-token="$(jq -r '.root_token' <<<"$init")" >/dev/null
  echo "Vault инициализирован, ключ и токен — в секрете vault/vault-unseal"
  status=$(kubectl -n "$VAULT_NS" exec vault-0 -c vault -- vault status -format=json 2>/dev/null || true)
fi

# Распечатать сразу, не дожидаясь соседнего контейнера (он увидит новый секрет через минуту-две)
if [[ $(jq -r '.sealed' <<<"$status") == true ]]; then
  # shellcheck disable=SC2016 # $KEY раскрывает оболочка внутри пода
  kubectl -n "$VAULT_NS" get secret vault-unseal -o jsonpath='{.data.unseal-key}' | base64 -d |
    kubectl -n "$VAULT_NS" exec -i vault-0 -c vault -- sh -c 'read -r KEY; vault operator unseal "$KEY" >/dev/null'
  echo "Vault распечатан"
fi

# 2. Хранилище секретов KV v2 по пути secret/
if ! vault_token | vault_cmd secrets list -format=json | jq -e 'has("secret/")' >/dev/null; then
  vault_token | vault_cmd secrets enable -path=secret kv-v2 >/dev/null
  echo "Включён KV v2: secret/"
fi

# 3. Вход по сервисным аккаунтам Kubernetes: Vault проверяет токен через API Kubernetes (TokenReview).
#    Адрес API и сертификат Vault берёт из своего пода
if ! vault_token | vault_cmd auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  vault_token | vault_cmd auth enable kubernetes >/dev/null
  echo "Включён вход через Kubernetes"
fi
vault_token | vault_cmd write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null

# Права External Secrets: читать любые секреты secret/* (писать — нет)
{ vault_token; echo; cat <<'EOF'; } | vault_cmd policy write external-secrets - >/dev/null
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
# Роль: токен сервисного аккаунта external-secrets из namespace external-secrets, выпущенный для Vault (aud=vault),
# → политика external-secrets на час
vault_token | vault_cmd write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  audience=vault \
  policies=external-secrets ttl=1h >/dev/null
echo "Vault настроен: secret/ (KV v2), вход external-secrets через Kubernetes"
