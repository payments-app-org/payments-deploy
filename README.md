# payments-deploy

Описание окружений payments-app в Kubernetes: какие сервисы и компоненты платформы, каких версий и с какими настройками в них работают. Окружение сейчас одно — `prod`, локальный кластер k3d на ноутбуке; структура папок готова к нескольким.

Кластер берёт всё отсюда сам. Внутри него работает **Argo CD**: раз в минуту он сверяет кластер с `main` этого репозитория и приводит кластер к описанию (GitOps). Руками в кластере ничего не меняем: изменение — это коммит сюда.

## Как новая версия сервиса попадает в кластер

1. PR в репозиторий сервиса (например, `payments-pricing`). CI проверяет его: тесты, Trivy, сборка образа.
2. Слили PR в `main`. CI сервиса снова всё проверяет и публикует образ `ghcr.io/payments-app-org/payments-pricing:<sha>` в GitHub Container Registry.
3. Задача `deploy` ждёт кнопки: в запуске CI — **Review deployments → prod → Approve and deploy** (окружение `prod` с обязательным подтверждением). После неё CI вызывает здесь `scripts/set-image.sh pricing <sha>` — тег попадает в `envs/prod/services/pricing.yaml` — и пушит коммит в `main` ключом развёртывания.
4. Argo CD видит коммит и выкатывает pricing: новый под → readiness → старый под гасится. Остальные сервисы не трогаются.

CI до кластера не достаёт: машины GitHub не видят ноутбук. Поэтому CI только пишет в git, а кластер сам забирает.

**Откат** — revert коммита с тегом в этом репозитории или «History and rollback» в Argo CD. Ручной откат Argo CD отменит при следующей сверке с git, если в git осталась новая версия. Надёжный откат — через git.

## Что где лежит

```
charts/                         наши шаблоны (Helm)
  java-service/                 общий шаблон Java-сервисов: Deployment, Service, HTTPRoute
  frontend/                     nginx со статикой
services/<сервис>.yaml          сервис во всех окружениях: порт, адреса соседей, секреты, пути входа
platform/<компонент>/values.yaml  чужие чарты (Traefik, Argo CD…) — общие настройки
infra/                          Postgres, Kafka, Redis — обычные манифесты

envs/prod/                      ← всё, чем отличается окружение prod
  root.yaml                     «главное» приложение Argo CD: создаёт всё из envs/prod/apps
  apps/                         какие приложения Argo CD работают в окружении
    projects.yaml               проекты Argo CD: platform и payments — что откуда и куда можно ставить
    services.yaml               ApplicationSet: по приложению на каждый сервис
    infra.yaml                  Postgres, Kafka, Redis
    platform/<компонент>.yaml   чарт компонента платформы и его версия
  env.yaml                      общее для сервисов окружения: вход (Gateway) и хосты
  services/<сервис>.yaml        версия образа, число подов, память
  platform/<компонент>.yaml     настройки компонента платформы в окружении: поды, память, хосты

cluster/k3d.yaml                кластер: один узел, порт 80 ноутбука — вход
scripts/                        cluster-up.sh — поднять всё; secrets.sh — секреты из payments-local/.env;
                                set-image.sh — записать версию образа; check.sh — проверка (CI)
```

**Правило:** поправить окружение (поды, память, версию) — в `envs/<окружение>/`. Поправить сервис во всех окружениях (новая переменная, путь) — в `services/`. Новое окружение — копия `envs/prod`, а `root.yaml` его кластера смотрит на эту копию.

Настройки сервиса складываются в три слоя, каждый следующий переопределяет предыдущий: `charts/<чарт>/values.yaml` (по умолчанию) → `services/<сервис>.yaml` → `envs/<окружение>/env.yaml` → `envs/<окружение>/services/<сервис>.yaml`. Посмотреть, во что шаблон превращается:
```bash
helm template pricing charts/java-service -f services/pricing.yaml -f envs/prod/env.yaml -f envs/prod/services/pricing.yaml
```

## Вход в кластер

```
браузер → localhost:80 → балансировщик k3d → Traefik (Ingress-контроллер)
  по правилам Gateway API (Gateway «external» + маршруты HTTPRoute):
    payments.localhost/api/<…>  → сервис
    payments.localhost/         → frontend
    argocd.localhost            → Argo CD
    traefik.localhost           → панель Traefik (какие маршруты он видит)
```

- **Traefik** — поды, которые принимают все запросы снаружи. Ставит его Argo CD из чарта (`envs/prod/apps/platform/traefik.yaml`), настройки — `platform/traefik/values.yaml` и `envs/prod/platform/traefik.yaml`. Встроенный в k3s Traefik выключен (`cluster/k3d.yaml`), чтобы версия и настройки были здесь.
- **Gateway API** — язык правил входа, на смену Ingress: `Gateway` — сам вход (порт, хосты; его создаёт чарт Traefik), `HTTPRoute` — маршрут сервиса (`charts/*/templates/httproute.yaml`). Типы Gateway API ставятся отдельным приложением `gateway-api`.

## Argo CD: что где настраивается

- **Установка** — `platform/argocd/values.yaml` + `envs/prod/platform/argocd.yaml`. Первый раз ставит `scripts/cluster-up.sh`, дальше Argo CD обновляет себя сам (приложение `argocd`): поменяли настройку или версию чарта — PR, после слияния он применит.
- **Что развернуть** — `envs/prod/apps/`. Приложение (Application) = откуда взять описание (репозиторий, путь или чарт и версия, файлы настроек) + куда поставить (namespace) + как синхронизировать: `automated` — само, без кнопки Sync; `prune` — удалили из git → удалить из кластера; `selfHeal` — поправили кластер руками → вернуть как в git; `retry` — не получилось (например, ещё нет нужных типов) → повторить.
- **Проекты** — `envs/prod/apps/projects.yaml`: `payments` может ставить только из этого репозитория и только в namespace `payments`; `platform` — из чартов производителей в любой namespace.
- Кнопки интерфейса (Sync, Refresh, удаление пода) ничего не сохраняют надолго: что не в git — Argo CD вернёт.

## Запуск

Нужны Docker, `k3d`, `kubectl`, `helm`. Кластер и docker compose вместе в память не помещаются: перед запуском кластера остановите compose (`docker compose stop` в `payments-local`).

```bash
scripts/cluster-up.sh                     # создать или запустить кластер, поставить Argo CD, секреты, окружение prod
kubectl get applications -n argocd        # приложения Argo CD и их состояние
kubectl get pods -n payments              # что запущено
kubectl -n payments logs deploy/pricing   # логи сервиса
k9s -n payments                           # то же в интерфейсе терминала
k3d cluster stop payments                 # остановить (освободить память), данные сохраняются
k3d cluster delete payments               # удалить кластер вместе с данными
```

- Приложение — http://payments.localhost.
- Argo CD — http://argocd.localhost, логин `admin`, пароль: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
- Панель Traefik — http://traefik.localhost/dashboard/.
- Swagger, внутренние API, база данных — через проброс порта:
  - `kubectl -n payments port-forward svc/pricing 8082`, затем http://localhost:8082/swagger-ui.html;
  - `kubectl -n payments port-forward svc/postgres 5433:5432`.

## Изменения

- **Настройка сервиса** (переменная, путь входа) — PR в `services/<сервис>.yaml`; число подов, память — в `envs/<окружение>/services/<сервис>.yaml`. Новая переменная, которую читает новый код, — сначала сюда, потом PR в сервис.
- **Шаблон** — PR в `charts/`: действует на все сервисы сразу. Перед слиянием посмотреть `helm template` нескольких сервисов.
- **Новый сервис** — строка в `envs/<окружение>/apps/services.yaml` + `services/<сервис>.yaml` + `envs/<окружение>/services/<сервис>.yaml`. Если у сервиса своя схема — `infra/postgres.yaml` (база уже создана — схему добавить руками или пересоздать кластер).
- **Компонент платформы** — версия чарта в `envs/<окружение>/apps/platform/<компонент>.yaml`, настройки — `platform/<компонент>/values.yaml` и `envs/<окружение>/platform/<компонент>.yaml`.
- **Секреты** в git не кладём. Секрет `payments-secrets` создаёт `scripts/secrets.sh` из `payments-local/.env`. Поменяли ключи — запустить скрипт и `kubectl -n payments rollout restart deployment`.
- **CI** этого репозитория — `scripts/check.sh` (запускается и локально): шаблоны сервисов с настройками каждого окружения, чарты платформы с нашими настройками, YAML, shellcheck. Проверка — `ok`. `main` защищён: без PR и зелёной `ok` не изменить. Исключение — ключ развёртывания (deploy key) CI сервисов: им пишутся только новые теги образов.

## Упрощения

- Одно окружение. Обычно перед продом есть тестовое, но на ноутбуке два не помещаются; структура `envs/` к ним готова.
- Postgres, Kafka и Redis — по одному экземпляру, без реплик и бэкапов, одинаковые для всех окружений (`infra/`).
- Пароль Postgres открытым текстом — как в compose. Ключи сервисов — в секрете, но не в git.
- Чарты без версий: изменение шаблона сразу действует на все сервисы.
- Вход только по HTTP: на `localhost` сертификаты не нужны.
