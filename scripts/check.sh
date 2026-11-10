#!/usr/bin/env bash
# Проверка описания окружений до слияния (CI, можно и локально): шаблоны сервисов собираются с настройками
# каждого окружения, чарты платформы — с нашими настройками, YAML читается, скрипты без типичных ошибок.
# Нужны helm, yq (mikefarah), shellcheck.
set -euo pipefail
cd "$(dirname "$0")/.."

for env_dir in envs/*/; do
  env=$(basename "$env_dir")

  # Сервисы: элементы ApplicationSet → чарт + три файла настроек (как их соберёт Argo CD)
  count=$(yq '.spec.generators[0].list.elements | length' "$env_dir/apps/services.yaml")
  for ((i = 0; i < count; i++)); do
    name=$(yq ".spec.generators[0].list.elements[$i].name" "$env_dir/apps/services.yaml")
    chart=$(yq ".spec.generators[0].list.elements[$i].chart" "$env_dir/apps/services.yaml")
    echo "::group::$env / $name (charts/$chart)"
    values=(-f "services/$name.yaml" -f "$env_dir/env.yaml" -f "$env_dir/services/$name.yaml")
    helm lint "charts/$chart" "${values[@]}"
    helm template "$name" "charts/$chart" "${values[@]}" > /dev/null
    echo "::endgroup::"
  done

  # Платформа: чужие чарты нужной версии с нашими настройками ($values/… — файлы этого репозитория)
  for app in "$env_dir"apps/platform/*.yaml; do
    chart=$(yq '.spec.sources[0].chart // ""' "$app")
    [[ -n "$chart" ]] || continue
    name=$(yq '.metadata.name' "$app")
    echo "::group::$env / $name (чарт $chart)"
    # shellcheck disable=SC2016 # $values — буквально, это не переменная оболочки
    mapfile -t files < <(yq '.spec.sources[0].helm.valueFiles[] | sub("^\$values/"; "")' "$app")
    values=()
    for f in "${files[@]}"; do values+=(-f "$f"); done
    helm template "$name" "$chart" \
      --repo "$(yq '.spec.sources[0].repoURL' "$app")" --version "$(yq '.spec.sources[0].targetRevision' "$app")" \
      --namespace "$(yq '.spec.destination.namespace' "$app")" "${values[@]}" > /dev/null
    echo "::endgroup::"
  done
done

# Все YAML, кроме шаблонов Helm (это не YAML, а текст с подстановками)
find . -name '*.yaml' -not -path './charts/*/templates/*' -not -path './.git/*' -print0 \
  | xargs -0 -n1 yq 'true' > /dev/null

shellcheck scripts/*.sh
echo "Проверка пройдена"
