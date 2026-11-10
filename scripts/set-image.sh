#!/usr/bin/env bash
# Записать версию образа сервиса в окружение: scripts/set-image.sh <сервис> <тег> [окружение, по умолчанию prod].
# Вызывает CI сервисов по кнопке выкатки (payments-ci, deploy.yml); вручную — то же самое, потом PR.
# Где лежит тег, знает только этот репозиторий: поменяется раскладка файлов — меняется скрипт, а не CI
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE=${1:?сервис}
TAG=${2:?тег образа}
ENV=${3:-prod}
FILE="envs/$ENV/services/$SERVICE.yaml"

[[ -f "$FILE" ]] || { echo "Нет файла $FILE: сервис $SERVICE не описан в окружении $ENV" >&2; exit 1; }
TAG="$TAG" yq -i '.image.tag = strenv(TAG)' "$FILE"
echo "$FILE: image.tag = $TAG"
