#!/usr/bin/env bash
# Подключить Telegram-бота к Alertmanager: токен бота и чат → Vault (secret/alertmanager).
# Дальше External Secrets собирает из них настройку Alertmanager (platform/kube-prometheus-stack/manifests).
#
# Перед запуском:
#   1. @BotFather → /newbot → имя и username бота → токен (строка вида 123456:ABC…) — скопировать его в буфер обмена
#   2. Открыть своего бота и нажать Start (или написать любое сообщение): бот не может писать первым,
#      а из этого сообщения скрипт узнаёт id чата
# Токен вводится скрытно и не попадает ни в историю команд, ни в аргументы процессов.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/vault-lib.sh
. scripts/vault-lib.sh

# Токен — из буфера обмена (скопировать в Telegram и запустить скрипт): так он не печатается в терминале и не
# попадает в историю команд. После чтения буфер очищается. Нет токена в буфере (или не macOS) — спросим скрытым вводом
input=$(pbpaste 2>/dev/null || true)
if [[ $input =~ ([0-9]{6,}:[A-Za-z0-9_-]{30,}) ]]; then
  echo "Токен взят из буфера обмена, буфер очищен"
  printf '' | pbcopy
else
  read -rsp "Токен бота от @BotFather (ввод скрыт, вставьте и нажмите Enter): " input
  echo
fi
# Терминал при вставке оборачивает текст служебными символами (bracketed paste: ESC[200~ … ESC[201~),
# могут попасть пробелы — берём только сам токен
[[ $input =~ ([0-9]{6,}:[A-Za-z0-9_-]{30,}) ]] || { echo "Это не похоже на токен бота (123456789:AA…)" >&2; exit 1; }
token=${BASH_REMATCH[1]}

# Запрос к Bot API: адрес с токеном — через stdin curl (-K -), а не аргументом
telegram() {
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$1" | curl -sS --max-time 15 -K - "${@:2}"
}

me=$(telegram getMe)
[[ $(jq -r '.ok' <<<"$me") == true ]] || { echo "Telegram не принял токен: $(jq -r '.description' <<<"$me")" >&2; exit 1; }
echo "Бот: @$(jq -r '.result.username' <<<"$me")"

# Последний личный чат, из которого писали боту (Start = сообщение /start)
chat_id=$(telegram getUpdates | jq -r '[.result[] | .message // empty | select(.chat.type == "private") | .chat.id] | last // empty')
[[ -n $chat_id ]] || { echo "Нет сообщений боту: откройте бота в Telegram, нажмите Start и запустите скрипт снова" >&2; exit 1; }

vault_write alertmanager "$(jq -n --arg t "$token" --arg c "$chat_id" '{bot_token: $t, chat_id: $c}')"
echo "Vault: secret/alertmanager (бот и чат)"

telegram sendMessage --data-urlencode "chat_id=$chat_id" \
  --data-urlencode "text=✅ Бот подключён к Alertmanager payments-app. Сюда будут приходить тревоги." >/dev/null
echo "Тестовое сообщение отправлено. Alertmanager подхватит настройку в течение минуты"
