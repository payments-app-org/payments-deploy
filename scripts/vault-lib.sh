#!/usr/bin/env bash
# Общие функции для работы с Vault в кластере (подключают scripts/vault-init.sh, secrets.sh, telegram.sh).
# Команды выполняются внутри пода vault-0 (kubectl exec). Токен передаётся первой строкой stdin, а не аргументом:
# аргументы видны в списке процессов узла.

VAULT_NS=vault

# Токен администратора (root) — в секрете vault-unseal, его создаёт scripts/vault-init.sh.
# В проде root-токен после настройки отзывают, люди входят через SSO (OIDC), сервисы — через Kubernetes
vault_token() {
  kubectl -n "$VAULT_NS" get secret vault-unseal -o jsonpath='{.data.root-token}' | base64 -d
}

# vault_cmd <аргументы vault…> — выполнить команду vault; если нужен ввод (политика, JSON), он — после токена
vault_cmd() {
  # shellcheck disable=SC2016 # $@ и $VAULT_TOKEN раскрывает оболочка внутри пода
  kubectl -n "$VAULT_NS" exec -i vault-0 -c vault -- \
    sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' sh "$@"
}

# vault_read <путь> — JSON с ключами секрета secret/<путь> или пустая строка, если его нет
vault_read() {
  vault_token | vault_cmd kv get -format=json "secret/$1" 2>/dev/null | jq -c '.data.data' || true
}

# vault_write <путь> <JSON> — записать секрет secret/<путь> целиком (новая версия в KV v2, старые хранятся)
vault_write() {
  { vault_token; echo; printf '%s' "$2"; } | vault_cmd kv put "secret/$1" - >/dev/null
}
