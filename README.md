# payments-deploy

Описание окружения payments-app в Kubernetes: какие сервисы, каких версий и с какими настройками в нём работают. Окружение одно — локальный кластер k3d на ноутбуке.

Кластер берёт всё отсюда сам. Внутри него работает **Argo CD**: раз в минуту он сверяет кластер с `main` этого репозитория и приводит кластер к описанию (GitOps). Руками в кластере ничего не меняем: изменение — это коммит сюда.

## Как новая версия сервиса попадает в кластер

1. PR в репозиторий сервиса (например, `payments-pricing`). CI проверяет его: тесты, Trivy, сборка образа.
2. Слили PR в `main`. CI сервиса публикует образ `ghcr.io/payments-app-org/payments-pricing:<sha>`, а задача `deploy` (шаблон `payments-ci/.github/workflows/deploy.yml`) записывает этот `<sha>` в `services/pricing.yaml` и пушит коммит в `main` этого репозитория.
3. Argo CD видит коммит и выкатывает pricing: новый под → readiness → старый под гасится. Остальные сервисы не трогаются.

CI до кластера не достаёт: машины GitHub не видят ноутбук. Поэтому CI только пишет в git, а кластер сам забирает.

**Откат** — revert коммита с тегом в этом репозитории или «History and rollback» в Argo CD. Ручной откат Argo CD отменит при следующей сверке с git, если в git осталась новая версия. Надёжный откат — через git.

## Что где лежит

```
charts/java-service/     общий шаблон 9 Java-сервисов (Helm)
  values.yaml            значения по умолчанию: память, JVM, хост входа
  templates/
    deployment.yaml      как запускать: образ, переменные, секреты, пробы, память, обновление без простоя
    service.yaml         внутренний адрес http://<сервис>:<порт>
    ingress.yaml         вход снаружи по путям /api/... (если у сервиса есть ingress.paths)
charts/frontend/         nginx со статикой фронтенда, вход по /
services/<сервис>.yaml   настройки сервиса: порт, образ и его тег, переменные, секреты, память, пути входа
infra/                   Postgres, Kafka, Redis — обычные манифесты (каждый один, шаблон не нужен)
argocd/
  values.yaml            установка Argo CD
  root.yaml              «главное» приложение: создаёт приложения из argocd/apps
  apps/<сервис>.yaml     приложение Argo CD: шаблон + services/<сервис>.yaml → namespace payments
cluster/k3d.yaml         кластер: один узел, порт 80 ноутбука — вход
scripts/                 cluster-up.sh — поднять всё; secrets.sh — секреты из payments-local/.env
```

Посмотреть, во что шаблон превращается для сервиса:
```bash
helm template pricing charts/java-service -f services/pricing.yaml
```

## Запуск

Нужны Docker, `k3d`, `kubectl`, `helm`. Кластер и docker compose вместе в память не помещаются: перед запуском кластера остановите compose (`docker compose stop` в `payments-local`).

```bash
scripts/cluster-up.sh                     # создать или запустить кластер, поставить Argo CD, секреты, приложения
kubectl get pods -n payments              # что запущено
kubectl -n payments logs deploy/pricing   # логи сервиса
k3d cluster stop payments                 # остановить (освободить память), данные сохраняются
k3d cluster delete payments               # удалить кластер вместе с данными
```

- Приложение — http://payments.localhost.
- Argo CD — http://argocd.localhost, логин `admin`, пароль: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
- Swagger, внутренние API, база данных — через проброс порта:
  - `kubectl -n payments port-forward svc/pricing 8082`, затем http://localhost:8082/swagger-ui.html;
  - `kubectl -n payments port-forward svc/postgres 5433:5432`.

## Изменения

- **Настройка сервиса** (переменная, память, путь входа) — PR сюда, в `services/<сервис>.yaml`. Новая переменная, которую читает новый код, — сначала сюда, потом PR в сервис.
- **Шаблон** — PR в `charts/`: действует на все сервисы сразу. Перед слиянием посмотреть `helm template` нескольких сервисов.
- **Новый сервис** — `services/<сервис>.yaml` + `argocd/apps/<сервис>.yaml`. Если у сервиса своя схема — `infra/postgres.yaml` (база уже создана — схему добавить руками или пересоздать кластер).
- **Секреты** в git не кладём. Секрет `payments-secrets` создаёт `scripts/secrets.sh` из `payments-local/.env`. Поменяли ключи — запустить скрипт и `kubectl -n payments rollout restart deployment`.
- **CI** этого репозитория: шаблоны собираются с настройками каждого сервиса, YAML читается, скрипты проверяет shellcheck. Проверка — `ok`. `main` защищён: без PR и зелёной `ok` не изменить. Исключение — ключ развёртывания (deploy key) CI сервисов: им пишутся только новые теги образов.

## Упрощения

- Одно окружение. Обычно перед продом есть тестовое, но на ноутбуке два не помещаются.
- Postgres, Kafka и Redis — по одному экземпляру, без реплик и бэкапов.
- Пароль Postgres открытым текстом — как в compose. Ключи сервисов — в секрете, но не в git.
- Чарты без версий: изменение шаблона сразу действует на все сервисы.
