# bisquite-teleport-agent

Агент Teleport на машине (робот, стенд, сервер): SSH-нода и веб-приложения
без входящих портов — Teleport сам держит обратный туннель к прокси на 443.
Пакет даёт CLI `bisquite-teleport`, юниты systemd и схему настроек; бинарь
`teleport` ставится отдельно.

Что умеет:

- `join` — регистрация одной командой (методы `token` и `bound_keypair`),
  проверка версии кластера до остановки агента, откат к прежней регистрации,
  стирание токена или секрета после регистрации;
- `/etc/teleport.yaml` собирается из `/etc/bisquite/teleport/config` на каждом
  старте службы: правка руками не расходится со `status`;
- веб-приложения на петле, объявленные другими пакетами в
  `/etc/bisquite/teleport/apps.d` (контракт ниже), и приложения оператора;
- динамическая метка `os_logins` — логины ОС машины;
- метки `space` и `env` с портала, реализующего контракт
  [`GET /robot-api/v1/labels`](docs/portal-labels-api.md) (например, Stvor).

Поддерживаются Debian 12 (bookworm), Debian 13 (trixie), Ubuntu 24.04 LTS
и 22.04 LTS, `amd64` и `arm64` (на `amd64` все четыре проверены установкой
пакета и регистрацией ноды в контейнерах); пакет архитектурно
независимый (`_all.deb`: bash, юниты, схема). Проект вырос из расширения
`teleport-agent` репозитория
[bisquite-extensions](https://github.com/iamletenkov/bisquite-extensions);
расширение 3.x — тонкая обёртка, которая ставит этот пакет в образ bisquite.

## Установка

1. **Teleport.** Агенту нужен один бинарь `teleport` в `/usr/local/bin/teleport`
   (`tsh`, `tctl`, `tbot` ноде не нужны). Версия — **не новее кластера** и не
   старше на мажор; для `bound_keypair` — не ниже 18.8.0. Например, из тарбола
   с CDN (или со своего зеркала — со сверкой по закреплённому sha256):

   ```bash
   V=18.10.0; A=$(dpkg --print-architecture)
   curl -fLO https://cdn.teleport.dev/teleport-v$V-linux-$A-bin.tar.gz
   echo "$(curl -fsSL https://cdn.teleport.dev/teleport-v$V-linux-$A-bin.tar.gz.sha256 | cut -d' ' -f1)  teleport-v$V-linux-$A-bin.tar.gz" | sha256sum -c -
   sudo tar -xzf teleport-v$V-linux-$A-bin.tar.gz -C /usr/local/bin --strip-components=1 teleport/teleport
   ```

2. **Пакет агента** — из релиза GitHub (или с зеркала портала), со сверкой
   суммы:

   ```bash
   V=3.0.1
   curl -fLO https://github.com/iamletenkov/bisquite-teleport-agent/releases/download/v$V/bisquite-teleport-agent_${V}_all.deb
   curl -fLO https://github.com/iamletenkov/bisquite-teleport-agent/releases/download/v$V/SHA256SUMS
   sha256sum -c SHA256SUMS
   sudo apt install ./bisquite-teleport-agent_${V}_all.deb
   ```

   Зависимости — `bash`, `curl`, `ca-certificates`, `util-linux`, `coreutils`;
   systemd рекомендован (без него агент только пишет настройки).

Установка ничего не регистрирует и агент не запускает: `teleport.service`
включает `join`. Поэтому пакет можно ставить в образ — копии образа не станут
одной нодой.

### Переход с расширения teleport-agent 2.x

Машина, прошитая образом bisquite с расширением `teleport-agent` 2.x,
переходит на пакет установкой `.deb` — без новой регистрации и без
перезапуска агента. `postinst`:

- переносит копии юнитов 2.x из `/etc/systemd/system` (они перекрывали бы
  юниты пакета и вызывали `/usr/local/sbin/bisquite-teleport`) в
  `/var/lib/bisquite/teleport/2.x-units/`; ссылки включения
  (`multi-user.target.wants/teleport.service`, `paths.target.wants/…`,
  `timers.target.wants/…`) переводит на юниты пакета — что было включено,
  остаётся включённым;
- `/usr/local/sbin/bisquite-teleport` становится ссылкой на
  `/usr/sbin/bisquite-teleport` (старые вызовы и уже собранный
  `teleport.yaml` работают);
- схема домена `teleport` (`/opt/bisquite/knobs/teleport{,.apply}`) —
  из пакета; ссылка `/usr/local/sbin/bisquite-conf` образа bisquite не
  меняется;
- **не трогает** `/etc/bisquite/teleport/config` (ни байта, даже умолчания
  не дописывает), `/var/lib/teleport` (регистрация), токен меток,
  `/etc/teleport.yaml` и работающий агент. Следующий старт агента собирает
  `teleport.yaml` уже новым CLI.

Юнит `teleport.service` в `/etc/systemd/system`, написанный не расширением
(например, скриптом установки портала), пакет не трогает и предупреждает: он
перекрывает юнит пакета.

Каталог расширения `/opt/bisquite/teleport-agent` остаётся на диске, но
больше ни на что не указывает.

## Подключение

Одна команда на машине — руками или из первой загрузки (cloud-init
`runcmd`, bisquite `firstboot-commands`):

```bash
echo '<токен>' | sudo bisquite-teleport join TELEPORT_PROXY=teleport.example.org TELEPORT_TOKEN=- TELEPORT_ENV=dev
```

`TELEPORT_TOKEN=-` читает токен со stdin: `echo` встроен в shell и в argv не
попадает, а аргумент `TELEPORT_TOKEN=<токен>` виден в `/proc/<pid>/cmdline`
всё время ожидания регистрации.

**Токен** — `tctl tokens add --type=node,app --ttl=<срок>`. Токен без роли
`app`: SSH-нода регистрируется, а `app_service` бесконечно повторяет «token
does not allow role App» — приложения не публикуются. Добавить роль к готовой
регистрации без нового токена нельзя; `join` и `status` об этом пишут, лечится
новым токеном `node,app` и `join … TELEPORT_FORCE=1`. После регистрации токен
стирается из конфига. Утёкший до истечения срока токен позволяет поднять
чужого агента — ответ на это срок и стирание, а не проверки на машине.

### Подключение по bound_keypair

Для кластера ≥ 18.8 (агент — тоже): токен `bound_keypair` выдаётся на одну
машину, секрет регистрации одноразовый, а после первой регистрации агент
подтверждает себя ключом, который он сам создал и держит в `/var/lib/teleport`.
Утечка секрета после регистрации ничего не даёт; утечка до неё — одна нода.

```bash
echo '<секрет регистрации>' | sudo bisquite-teleport join TELEPORT_PROXY=teleport.example.org \
    TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=<имя токена> TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dev
```

Токен на стороне кластера (`tctl create`):

```yaml
kind: token
version: v2
metadata:
  name: robot-01                 # это TELEPORT_TOKEN
spec:
  roles: [Node, App]             # App — иначе приложения не публикуются
  join_method: bound_keypair
  bound_keypair:
    onboarding:
      registration_secret: "…"   # или пусто — Teleport сгенерирует сам
      must_register_before: "…"  # необязательно: срок первой регистрации
    recovery:
      mode: standard
      limit: 1
```

Секрет — `TELEPORT_REGISTRATION_SECRET=-` (stdin), значением (хуже, виден в
argv) или файлом `TELEPORT_REGISTRATION_SECRET_FILE=<путь>` (файл `join` не
удаляет). Требования — 8–1024 печатных знаков без пробелов.

- Секрет не ручка: в `/etc/bisquite/teleport/config` его нет, `status` пишет
  только «задан». Он лежит в `/var/lib/bisquite/teleport/registration-secret`
  (0600, каталог 0700), `teleport.yaml` ссылается на путь, а не на значение.
- После регистрации (`host_uuid`) секрет стирается, и блок `bound_keypair:`
  уходит из `teleport.yaml`. Имя токена и метод остаются: при новой системной
  роли или ротации CA агент переподключается связанным ключом без секрета.
- Ключ живёт в `/var/lib/teleport`. Повтор `join` при той же регистрации
  ничего не трогает. Стирают ключ только `leave`, `join … TELEPORT_FORCE=1` и
  `join` в другой прокси — после них нужен новый секрет регистрации.
- `join` без `TELEPORT_JOIN_METHOD` — это `token`, даже если машина была
  подключена по `bound_keypair`: метод идёт от команды, а не от истории.

## Команды

```
bisquite-teleport join KEY=VALUE…   зарегистрироваться (первая загрузка, переезд)
bisquite-teleport set KEY=VALUE…    env, метки, приложения — без переподключения
bisquite-teleport leave             агент выключен, регистрация стёрта
bisquite-teleport status            что настроено и что опубликовано
bisquite-teleport labels-enable URL=…    метки с портала: токен со stdin, таймер
bisquite-teleport pull              один тик: забрать метки и применить (зовёт таймер)
bisquite-teleport set-managed env=… space=…   метки портала одним перезапуском
bisquite-teleport version           версия пакета
```

### join

| Ключ | Обязателен | Что |
|---|---|---|
| `TELEPORT_PROXY` | да | `host[:port]`, без порта — 443 |
| `TELEPORT_JOIN_METHOD` | нет | `token` (по умолчанию) или `bound_keypair` |
| `TELEPORT_TOKEN` | да | `token`: токен или `-` (stdin); `bound_keypair`: имя токена |
| `TELEPORT_REGISTRATION_SECRET` | для `bound_keypair` | секрет регистрации или `-` (stdin); stdin читает только один ключ |
| `TELEPORT_REGISTRATION_SECRET_FILE` | вместо предыдущего | путь к файлу с секретом |
| `TELEPORT_ENV` | фактически да | метка `env`; по ней роли кластера обычно и дают доступ |
| `TELEPORT_CA_PIN` | нет | `sha256:…` из `tctl status`; у прокси с публичным сертификатом TLS проверяется и без него |
| `TELEPORT_NODENAME` | нет | по умолчанию короткое имя хоста |
| `TELEPORT_LABELS` | нет | `site=lab,robot=r1`; ключи `env`, `app`, `managed_by`, `bisquite_agent_version`, `os_logins`, `teleport.icon` — отказ |
| `TELEPORT_FORCE` | нет | `1` — переподключиться к тому же кластеру заново |

Что делает `join`, по порядку:

1. **Уже зарегистрирован в этом же прокси** — ничего не стирает, применяет
   метки и выходит. Повтор первой загрузки (клон носителя, `cloud-init clean`)
   не убивает рабочую ноду просроченным токеном.
2. **Предпроверка до остановки агента:** `https://<прокси>/webapi/find` с
   проверкой TLS, версия агента против `server_version`; для `bound_keypair` —
   агент не ниже 18.8.0 и секрет задан. Если машина была зарегистрирована,
   недоступный прокси — отказ, прежнее подключение цело. Если не была (сети
   ещё нет) — предупреждение: агент стартует и повторяет попытки сам.
3. Прежнее состояние — в `/var/lib/bisquite/teleport/rollback`, чистый
   `/var/lib/teleport` (кешированная CA прежнего кластера иначе даёт
   `no authorities for hostname`), конфиг, старт.
4. Ждёт `host_uuid` до 120 с (`BISQUITE_TELEPORT_JOIN_TIMEOUT`). Не дождался,
   а прежняя регистрация была — **возвращает её** и завершается ошибкой.

### set

`TELEPORT_ENV`, `TELEPORT_NODENAME`, `TELEPORT_LABELS`, `TELEPORT_APPS`,
`TELEPORT_APPS_DISABLE`, `TELEPORT_APPS_ICONS`, `TELEPORT_APPS_DISCOVERY`,
`TELEPORT_OS_LOGINS`, `TELEPORT_CA_PIN`. Применяет к работающему агенту
через reload (HUP — мягкий перезапуск Teleport, открытые SSH-сессии живут).
`TELEPORT_PROXY`, `TELEPORT_JOIN_METHOD` и `TELEPORT_TOKEN` — только `join`.

`bisquite-teleport set` — то же, что `sudo bisquite-conf set --apply teleport …`:
значения проверяет схема `knobs` (каждое значение ложится в YAML в двойных
кавычках, поэтому шаблоны исключают кавычки, `$` и переводы строки), пишет
библиотека `bisquite-conf`, а хук `knobs.apply` (`bisquite-teleport apply`)
собирает `teleport.yaml` и ставит reload в очередь без ожидания — `set`
бывает и внутри `cloud-final`.

### leave

Выключает агент и таймер меток, стирает `/var/lib/teleport`,
`teleport.yaml`, токены, токен меток и состояние меток. Запись ноды в
кластере сама не удаляется — у ноды нет на это прав; она исчезнет по
истечении heartbeat.

## Метки с портала

Портал — источник правды о том, в каком пространстве машина. Он управляет
ровно двумя метками: `space` (один элемент `TELEPORT_LABELS`) и `env`
(`TELEPORT_ENV`); прочие метки оператора не трогаются. Контракт, формат
ответа и поведение агента — [docs/portal-labels-api.md](docs/portal-labels-api.md).

```bash
read -rs T && printf '%s' "$T" | sudo bisquite-teleport labels-enable URL=https://<портал>/robot-api/v1/labels; unset T
```

Из первой загрузки — **второй** командой после `join`, со своим `|| true`:
отказ портала не должен ронять регистрацию.

`labels-enable`, `set-managed` и `pull` идут под одной блокировкой
(`flock` на `/var/lib/bisquite/teleport/.labels.lock`).

**Перезапуск, а не reload.** Смена `space`/`env` — `systemctl restart
teleport.service` с подтверждением нового запуска (`InvocationID`,
`MainPID` или `ActiveEnterTimestampMonotonic`). HUP оставил бы открытыми
SSH-сессии людей прежнего пространства, а приложения уже проверялись бы по
новым меткам. Перезапуск рвёт открытые сессии, машина недоступна 5–10 секунд,
узел и приложения переезжают одновременно.

## Метка os_logins

Нода публикует динамическую метку `os_logins` — список логинов ОС, под
которыми на машину вообще можно войти (`os_logins=robot,root`). **Метка —
справка, а не право:** кто и под каким логином входит, решают роли Teleport.

Считает её `bisquite-teleport os-logins`, агент запускает команду сам раз в
5 минут (`ssh_service.commands`, `period: 5m0s`):

- источник — NSS (`getent passwd`); `root` и учётки с uid ≥ 1000, кроме
  `nobody`; shell не `nologin`, `false`, `true`, `sync`, `shutdown`, `halt`;
- имя вне алфавита метки (`[A-Za-z0-9._-]`, до 32 знаков) пропускается, а не
  искажается;
- дубли убраны, порядок — `LC_ALL=C`; длиннее 255 знаков — обрезается по
  целому имени и заканчивается `,...`;
- код всегда 0: на ненулевом коде Teleport кладёт в метку текст ошибки.

Выключить — `sudo bisquite-teleport set TELEPORT_OS_LOGINS=0`. Задать
`os_logins` через `TELEPORT_LABELS` нельзя: динамическая метка побеждает
статическую, и значение оператора молча терялось бы.

## Приложения

| Откуда | Кто пишет | Адрес |
|---|---|---|
| `/etc/bisquite/teleport/apps.d/<имя>.conf` | другие пакеты и расширения | только петля |
| `TELEPORT_APPS=имя=порт,имя=URI` | оператор | любой; `порт` — `http://127.0.0.1:<порт>` |
| `TELEPORT_APPS_DISABLE=имя,…` | оператор | не публиковать |
| `TELEPORT_APPS_ICONS=имя=иконка,…` | оператор | иконка в веб-морде |

Одно имя в обоих — побеждает `TELEPORT_APPS`. `TELEPORT_APPS_DISCOVERY=0`
игнорирует `apps.d` целиком. Приложение публикуется как `<имя>-<нода>` с
адресом `<имя>.<нода>.<хост прокси>`.

### Контракт apps.d

Публичный интерфейс агента для других пакетов (так объявляют себя
`code-server` и `selkies` из bisquite-extensions). Файл
`/etc/bisquite/teleport/apps.d/<имя>.conf`:

```
NAME=code-server
URI=https://127.0.0.1:9002
ICON=laptop
```

Два обязательных ключа и один необязательный. Файл пропускается целиком
(с предупреждением в журнале), если:

- владелец не root, права шире `0644` или это символическая ссылка;
- есть другой ключ или строка не `KEY=VALUE` — разбор без `source`;
- `NAME` не метка DNS (`[a-z0-9-]`, из него строится адрес);
- `URI` не `http(s)://127.0.0.1|localhost|[::1][:порт][/путь]`;
- `ICON` не `[A-Za-z0-9._-]`;
- имя уже объявлено другим файлом (побеждает первый по алфавиту).

**Метку доступа объявление задать не может.** Приложение получает метки ноды
плюс `app=<NAME>`; кому оно видно, решает `TELEPORT_ENV` оператора. Файл в
`apps.d` не открывает приложение чужому `env`. Единственная метка, которую
задаёт объявление, — `teleport.icon` (иконка из набора, вшитого в прокси;
опечатка молчит — прокси угадывает иконку по имени).

Изменение в `apps.d` подхватывает `bisquite-teleport-apps.path` — reload
агента без участия человека. https на петле публикуется с
`insecure_skip_verify`; приложению на петле переписывается заголовок `Host`
на публичный адрес (иначе приложения, сверяющие Origin WebSocket с `Host`,
отвечают 403).

## teleport.yaml

`/etc/teleport.yaml` генерируется на каждом старте службы из
`/etc/bisquite/teleport` и руками не правится. Перед генерацией `render`
сверяет весь файл ручек со схемой: правка руками с кавычкой или `$` — отказ
старта, а не испорченный YAML.

- `ssh_service.listen_addr: 127.0.0.1:3022` — наружу порт не нужен;
- метки ноды: `TELEPORT_LABELS`, `managed_by=bisquite-teleport-agent`,
  `bisquite_agent_version=<версия пакета>`, `env`;
- `join_params` — пока есть токен (`token`) или секрет (`bound_keypair`);
- `commands` с `os_logins` — `["/usr/sbin/bisquite-teleport", "os-logins"]`.

## Файлы

| Путь | Права | Что |
|---|---|---|
| `/usr/local/bin/teleport` | 0755 | агент Teleport — ставится отдельно |
| `/usr/sbin/bisquite-teleport` | ссылка | CLI → `/usr/lib/bisquite-teleport/bisquite-teleport` |
| `/usr/lib/bisquite-teleport/` | | CLI, схема `knobs`, хук `knobs.apply`, `lib/bisquite-conf`, `pkg-setup` |
| `/usr/lib/systemd/system/` | | `teleport.service`, `bisquite-teleport-{apps,token}.{path,service}`, `bisquite-teleport-labels.{service,timer}` |
| `/opt/bisquite/knobs/teleport{,.apply}` | ссылки | схема и хук — там их ищет `bisquite-conf` |
| `/etc/bisquite/teleport/config` | 0600 | ручки (`bisquite-conf show teleport`) |
| `/etc/bisquite/teleport/apps.d/` | 0755 | объявления приложений |
| `/etc/bisquite/teleport/labels-token` | 0600 | `url=…` и `token=…` меток портала |
| `/etc/teleport.yaml` | 0600 | генерируется |
| `/var/lib/teleport/` | 0750 | регистрация агента; у `bound_keypair` — и связанный ключ |
| `/var/lib/bisquite/teleport/` | 0700 | `rollback`, секрет регистрации до регистрации, состояние меток, `2.x-units/` |

Юниты: `teleport.service` включает `join`; path-юниты включены всегда (до
регистрации ничего не делают); таймер меток включает `labels-enable`.

## Удаление

`apt remove` останавливает таймер меток и path-юниты, но не агент: удаление
не должно рвать сессию, из которой его запустили. Ни `remove`, ни `purge`
**не стирают регистрацию**: `/var/lib/teleport`, `/etc/bisquite/teleport` и
`/etc/teleport.yaml` остаются. Отключить машину — `sudo bisquite-teleport
leave` **до** удаления пакета.

## Диагностика

```bash
sudo bisquite-teleport status
journalctl -u teleport -f
journalctl -u bisquite-teleport-labels   # тики меток: ни токена, ни тела ответа там нет
```

## Разработка

```bash
make check     # shellcheck (если установлен) и все tests/test-*.sh
make deb       # dist/bisquite-teleport-agent_<версия>_all.deb и dist/SHA256SUMS
```

Тесты идут на подменённом корне (`BISQUITE_TELEPORT_ROOT`) с поддельными
`systemctl`, `curl`, `dpkg` и `teleport`: root, systemd и сеть не нужны.
Сборка `.deb` — `dpkg-deb` без debhelper, воспроизводимая
(`SOURCE_DATE_EPOCH` — время последнего коммита).

`lib/bisquite-conf` — копия библиотеки настроек bisquite-extensions; правки
вносятся там и переносятся сюда той же версией.

Уязвимости — [SECURITY.md](SECURITY.md). Изменения — [CHANGELOG.md](CHANGELOG.md).

### Как выпустить версию

Версию и `CHANGELOG.md` ведёт [release-please](https://github.com/googleapis/release-please)
(`.github/release_please/`), workflow `CI and Release`:

1. Сливаешь в `main` коммиты по [Conventional Commits](https://www.conventionalcommits.org/ru/):
   `fix:` поднимает patch, `feat:` — minor, `!` или `BREAKING CHANGE:` — major;
   `docs:`, `ci:`, `chore:` версию не трогают.
2. После проверок на `main` release-please открывает (и дальше обновляет)
   PR «chore(main): release X.Y.Z» — он поднимает `VERSION` и дописывает
   секцию в `CHANGELOG.md`.
3. Владелец сливает этот PR. release-please создаёт тег `vX.Y.Z` и
   опубликованный релиз с заметками из секции, затем job
   `release-artifacts` собирает из тега `.deb` и `SHA256SUMS` и прикладывает
   их к релизу.

Теги руками не ставят. Если сборка файлов упала, релиз уже виден без них:
«Re-run failed jobs» в том же прогоне или ручной запуск с `release_tag`:

```bash
gh workflow run ci-release.yml --ref main -f release_tag=vX.Y.Z
```

## Лицензия

[PolyForm Noncommercial 1.0.0](LICENSE), см. [NOTICE](NOTICE). Коммерческое
использование — по отдельной лицензии правообладателя.
