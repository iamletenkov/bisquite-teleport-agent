# teleport-agent

Агент Teleport на машине: SSH-нода и веб-приложения, без входящих портов —
агент сам держит обратный туннель к прокси на 443.

> **С 2.0.0 — раскладка 2.** Каталог расширения в госте — `/opt/bisquite/teleport-agent/`
> (был `/opt/vmsetup/teleport-agent/`); состояние CLI (`rollback` при `join`) переехало из `/var/lib/bisquite-teleport`
> в `/var/lib/bisquite/teleport`.
> Нужен bisquite с поддержкой `layout: 2`.

> **С 2.4.0 — join `bound_keypair` и Teleport 18.10.0 по умолчанию.**
> `TELEPORT_JOIN_METHOD=bound_keypair`: имя токена плюс одноразовый секрет
> регистрации, дальше агент подключается связанным ключом из
> `/var/lib/teleport` (см. «Подключение по bound_keypair»). Метод `token` —
> по-прежнему по умолчанию, и его `teleport.yaml` не изменился ни байтом.
> Умолчание `TELEPORT_VERSION` — `18.10.0`: образ без явной версии больше не
> подключится к кластеру старше 18.10.0 (`join` откажет: агент новее
> кластера) — для такого кластера версию задают явно, как в примерах bisquite.

> **С 2.3.0 — метка `os_logins`.** Нода публикует список логинов ОС
> динамической меткой (см. «Метка os_logins»); выключается
> `TELEPORT_OS_LOGINS=0`. Ключ `os_logins` в `TELEPORT_LABELS` — отказ.

> **С 2.1.0 — библиотека настроек.** `/etc/bisquite/teleport/config` — домен
> `teleport` библиотеки `bisquite-conf` (схема `knobs`): `bisquite-teleport`
> больше не держит свои разбор и проверки значений, `bisquite-conf set teleport …`
> и `bisquite-teleport set …` — одна и та же проверка. CLI ставится ссылкой.

Образ **нейтрален к кластеру**: на сборке ставятся бинарь, CLI и юниты, а
адрес кластера, `env` и токен задаются на устройстве одной командой. Один
образ подключается к разным кластерам и `env`, и переезд — та же команда.

Разбор решений — спека bisquite `docs/specs/2026-09-14-teleport-agent.md`.
Совместим со стеком `teleport-keycloak-ldap`: форма `teleport.yaml` та же, что
у его install.sh, так что роль `smart_role`, список нод в админке и адреса
приложений `<app>.<нода>.teleport.<домен>` работают без правок стека.

## Сборка

```
EXTENSION teleport-agent TELEPORT_VERSION=18.10.0 \
    TELEPORT_MIRROR=https://binaries.example.org
```

| Параметр | Умолчание | Что делает |
|---|---|---|
| `TELEPORT_VERSION` | `18.10.0` | версия агента; **не новее кластера**, не старше на мажор; для `bound_keypair` — не ниже 18.8.0 |
| `TELEPORT_MIRROR` | пусто | зеркало бинарей: `<база>/binaries/teleport/<версия>/teleport-v<версия>-linux-<arch>-bin.tar.gz` (раскладка `teleport-keycloak-ldap`); пусто — `cdn.teleport.dev` |
| `TELEPORT_SHA256` | пусто | хеш tarball; пусто — `.sha256` с `cdn.teleport.dev` (второй канал, если tarball с зеркала) |

Архитектура tarball — из `dpkg --print-architecture`: `amd64` или `arm64`
(Debian, Ubuntu, Raspberry Pi OS 64-bit, JetPack на Jetson). 32-битный
`armhf` манифест не объявляет, и `install.sh` на нём отказывает.

**Своя сборка Teleport на зеркале.** Tarball пересобранного форка той же
версии — не тот, что описывает `.sha256` с CDN, и сверка по нему упадёт
(`install.sh` так и скажет). Для форка `TELEPORT_SHA256` задают явно — хешем
tarball зеркала под архитектуру образа:

```
EXTENSION teleport-agent TELEPORT_VERSION=18.10.0 \
    TELEPORT_MIRROR=https://binaries.example.org \
    TELEPORT_SHA256=<sha256 teleport-v18.10.0-linux-arm64-bin.tar.gz с зеркала>
```

Агенту форк не нужен, если патчи форка касаются только auth/proxy: vanilla
18.10.0 с CDN (или с зеркала под тем же хешем) подключается к кластеру-форку
18.10.0 так же.

Ставится только `teleport` (308 МБ на arm64): `tsh`, `tctl`, `tbot` ноде
не нужны. Агент на сборке **не запускается** — регистрация в
`/var/lib/teleport` сделала бы все копии образа одной нодой; `install.sh`
отказывает, если она там уже есть.

## Подключение — на устройстве

Из манифеста записи (`firstboot-commands`):

```yaml
firstboot-commands:
  - "echo '<токен>' | bisquite-teleport join TELEPORT_PROXY=teleport.example.org TELEPORT_TOKEN=- TELEPORT_ENV=dst"
```

или руками на работающей машине — то же с `sudo`.

`TELEPORT_TOKEN=-` читает токен со stdin: `echo` встроен в shell и в argv не
попадает, а аргумент `TELEPORT_TOKEN=<токен>` виден в `/proc/<pid>/cmdline`
всё время ожидания регистрации. Можно и так, но хуже.

**Токен** — `tctl tokens add --type=node,app --ttl=<срок>` (в админке стека —
флажок «Разрешить веб-приложения без списка ниже»), срок — от записи носителя
до первой загрузки. Токен без роли `app`: SSH-нода регистрируется, а
`app_service` бесконечно повторяет «token does not allow role App» —
приложения не публикуются (замер на AGX Orin, Teleport 18.6.8). Добавить роль
к готовой регистрации без нового токена нельзя; `join` и `status` об этом
пишут, лечится новым токеном `node,app` и `join … TELEPORT_FORCE=1`. После регистрации токен
стирается из конфига. Seed на носителе стирайте:
`seed-cleanup: wipe-after-first-boot`. Утёкший до истечения срока токен
позволяет поднять чужого агента — ответ на это срок и стирание, а не проверки
на роботе.

### Подключение по bound_keypair

Для кластера ≥ 18.8 (агент — тоже): токен `bound_keypair` выдаётся на одного
робота, секрет регистрации одноразовый, а после первой регистрации агент
подтверждает себя ключом, который он сам создал и держит в `/var/lib/teleport`.
Утечка секрета после регистрации ничего не даёт; утечка до неё — одна нода,
а не сколько угодно.

```yaml
firstboot-commands:
  - "echo '<секрет регистрации>' | bisquite-teleport join TELEPORT_PROXY=teleport.example.org TELEPORT_JOIN_METHOD=bound_keypair TELEPORT_TOKEN=<имя токена> TELEPORT_REGISTRATION_SECRET=- TELEPORT_ENV=dst"
```

Токен на стороне кластера (`tctl create`):

```yaml
kind: token
version: v2
metadata:
  name: robot-orin-01            # это TELEPORT_TOKEN
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

Секрет — `TELEPORT_REGISTRATION_SECRET=-` (stdin), значением
(`TELEPORT_REGISTRATION_SECRET=<секрет>` — хуже, виден в argv) или файлом
`TELEPORT_REGISTRATION_SECRET_FILE=<путь>` (например, из `write_files`
cloud-init; файл `join` не удаляет). Требования — 8–1024 печатных знаков без
пробелов; пробелы и перевод строки по краям отбрасываются.

- Секрет не ручка: в `/etc/bisquite/teleport/config` его нет, `status` пишет
  только «задан». Он лежит в `/var/lib/bisquite/teleport/registration-secret`
  (0600, каталог 0700), `teleport.yaml` ссылается на путь, а не на значение.
- После регистрации (`host_uuid`) секрет стирается, как токен у `token`, и
  блок `bound_keypair:` уходит из `teleport.yaml`. Имя токена и метод
  остаются: при новой системной роли или ротации CA агент переподключается
  связанным ключом без секрета.
- Ключ живёт в `/var/lib/teleport` и переживает перезагрузки. Повтор `join`
  (клон носителя, `cloud-init clean`) при той же регистрации ничего не
  трогает. Стирают ключ только `leave`, `join … TELEPORT_FORCE=1` и `join` в
  другой прокси — после них нужен новый секрет регистрации (новый токен или
  сброс старого на кластере).
- `credential_ttl`, режим восстановления, ротация ключа — настройки токена
  на кластере; на роботе задавать нечего.
- `join` без `TELEPORT_JOIN_METHOD` — это `token`, даже если робот был
  подключён по `bound_keypair`: метод идёт от команды, а не от истории.

## Команды

```
bisquite-teleport join KEY=VALUE…   зарегистрироваться (первая загрузка, переезд)
bisquite-teleport set KEY=VALUE…    env, метки, приложения — без переподключения
bisquite-teleport leave             агент выключен, регистрация стёрта
bisquite-teleport status            что настроено и что опубликовано
```

### join

| Ключ | Обязателен | Что |
|---|---|---|
| `TELEPORT_PROXY` | да | `host[:port]`, без порта — 443 |
| `TELEPORT_JOIN_METHOD` | нет | `token` (по умолчанию) или `bound_keypair` |
| `TELEPORT_TOKEN` | да | `token`: токен или `-` (stdin); `bound_keypair`: имя токена |
| `TELEPORT_REGISTRATION_SECRET` | для `bound_keypair` | секрет регистрации или `-` (stdin); только один ключ может читать stdin |
| `TELEPORT_REGISTRATION_SECRET_FILE` | вместо предыдущего | путь к файлу с секретом |
| `TELEPORT_ENV` | фактически да | метка `env`: по ней `smart_role` даёт доступ; без неё ноду видят только `access`/`editor` |
| `TELEPORT_CA_PIN` | нет | `sha256:…` из `tctl status`; у прокси с публичным сертификатом TLS проверяется и без него |
| `TELEPORT_NODENAME` | нет | по умолчанию короткое имя хоста (из cloud-init) |
| `TELEPORT_LABELS` | нет | `site=lab,robot=orin`; ключи `env`, `app`, `managed_by`, `os_logins`, `teleport.icon` — отказ |
| `TELEPORT_FORCE` | нет | `1` — переподключиться к тому же кластеру заново |

Что делает `join`, по порядку:

1. **Уже зарегистрирован в этом же прокси** — ничего не стирает, применяет
   метки и выходит. Повтор `runcmd` (клон носителя, `cloud-init clean`) не
   убивает рабочую ноду просроченным токеном из seed.
2. **Предпроверка до остановки агента:** `https://<прокси>/webapi/find` с
   проверкой TLS, версия агента против `server_version`; для `bound_keypair` —
   агент не ниже 18.8.0 и секрет регистрации задан. Если машина была
   зарегистрирована, недоступный прокси — отказ, прежнее подключение цело.
   Если не была (первая загрузка, сети ещё нет) — предупреждение: агент
   стартует и повторяет попытки сам.
3. Прежнее состояние — в `/var/lib/bisquite/teleport/rollback`, чистый
   `/var/lib/teleport` (кешированная CA прежнего кластера иначе даёт
   `no authorities for hostname`), конфиг, старт.
4. Ждёт `host_uuid` до 120 с (`BISQUITE_TELEPORT_JOIN_TIMEOUT`). Не дождался,
   а прежняя регистрация была — **возвращает её** и завершается ошибкой.

### set

`TELEPORT_ENV`, `TELEPORT_NODENAME`, `TELEPORT_LABELS`, `TELEPORT_APPS`,
`TELEPORT_APPS_DISABLE`, `TELEPORT_APPS_ICONS`, `TELEPORT_APPS_DISCOVERY`,
`TELEPORT_OS_LOGINS`, `TELEPORT_CA_PIN`.
Применяет к работающему агенту через reload (HUP — мягкий перезапуск Teleport,
открытые SSH-сессии живут). `TELEPORT_PROXY`, `TELEPORT_JOIN_METHOD` и `TELEPORT_TOKEN` — только `join`:
в схеме они `ro:`, и `set` отказывает текстом из неё.

`bisquite-teleport set` — то же, что `sudo bisquite-conf set --apply teleport …`:
значения проверяет схема `knobs` (шаблоны те же, что у ldap-admin-api: каждое
значение ложится в YAML в двойных кавычках), пишет библиотека, а хук
`knobs.apply` (`bisquite-teleport apply`) собирает `teleport.yaml` и ставит
reload в очередь без ожидания — `set` бывает и внутри `cloud-final`.
Зарезервированные ключи меток (`env`, `app`, `managed_by`, `os_logins`, `teleport.icon`)
проверяет сам `bisquite-teleport` — в `set`, `join` и `render`.

### leave

Запись ноды в кластере сама не удаляется — у ноды нет на это прав. Она
исчезнет по истечении heartbeat, либо удаляется в админке.

## Метка os_logins

Нода публикует динамическую метку `os_logins` — список логинов ОС, под
которыми на машину вообще можно войти:

```
os_logins=robot,root
```

Зачем: портал Stvor показывает оператору список доступных логинов робота,
проверяет по нему логины в заявках и ролях и следит, когда нужная учётка
появилась (например, после `cloud-init` или установки расширения). **Метка —
справка, а не право:** кто и под каким логином входит, по-прежнему решают роли
Teleport (`logins` роли, `smart_role`); метка ничего не открывает и не
закрывает.

Как считается — команда `bisquite-teleport os-logins`, её агент запускает сам
раз в 5 минут (`ssh_service.commands` Teleport, `period: 5m0s`):

- источник — NSS (`getent passwd`): локальные учётки и каталоги, которые NSS
  перечисляет (sssd по умолчанию не перечисляет — таких пользователей в
  списке не будет);
- `root` и учётки с uid ≥ 1000, кроме `nobody` (65534); системные с uid < 1000
  не попадают, даже если у них есть shell;
- shell не `nologin`, `false`, `true`, `sync`, `shutdown`, `halt`; пустое поле
  shell — это `/bin/sh`, учётка попадает;
- имя вне алфавита метки (`[A-Za-z0-9._-]`, до 32 знаков, например `ad$`)
  пропускается, а не искажается: искажённое имя было бы логином, которого нет;
- дубли убраны, порядок — байтовая сортировка (`LC_ALL=C`), через запятую;
- длиннее 255 знаков — обрезается по целому имени и заканчивается `,...`;
- команда всегда выходит с кодом 0: на ненулевом коде Teleport кладёт в метку
  текст ошибки. Не прочитался `passwd` — метка пустая.

Новая учётка видна в метке не позже чем через 5 минут, без перезапуска агента.
Выключить — `sudo bisquite-teleport set TELEPORT_OS_LOGINS=0`: секции
`commands` в `teleport.yaml` не будет, метка пропадёт после reload. Задать
`os_logins` руками через `TELEPORT_LABELS` нельзя — отказ, как для `env`:
у Teleport динамическая метка побеждает статическую с тем же ключом, и
значение оператора молча терялось бы. Метку получает только нода, не
приложения.

## Приложения

Два источника, выключатель и иконки:

| Откуда | Кто пишет | Адрес |
|---|---|---|
| `/etc/bisquite/teleport/apps.d/<имя>.conf` | расширения на сборке | только петля |
| `TELEPORT_APPS=имя=порт,имя=URI` | оператор | любой; `порт` — `http://127.0.0.1:<порт>` |
| `TELEPORT_APPS_DISABLE=имя,…` | оператор | не публиковать |
| `TELEPORT_APPS_ICONS=имя=иконка,…` | оператор | иконка в веб-морде |

Одно имя в обоих — побеждает `TELEPORT_APPS`. `TELEPORT_APPS_DISCOVERY=0`
игнорирует `apps.d` целиком.

### Иконки

Веб-морда прокси рисует приложению иконку из набора, **вшитого в бинарь
прокси** (около 244 имён: `docker`, `grafana`, `jenkins`, `argocd`,
`prometheus`, `mcpVscode`, `desktop`, `server`, `application`…). Своя картинка
с ноды приехать не может: поля иконки в API приложения нет вовсе, и
единственный канал — метка `teleport.icon`, которую и ставит `bisquite-teleport`.

Кто задаёт, в порядке силы: `TELEPORT_APPS_ICONS` оператора, затем `ICON=`
в объявлении расширения. **Не задал никто — метки нет вовсе**, и тогда прокси
угадывает по имени приложения сам: `grafana` получит иконку Grafana бесплатно,
`selkies` — серую заглушку `application`.

Два края, о которых надо знать:

- **Опечатка молчит.** Список имён вшит в прокси, и с ноды его не видно:
  `bisquite-teleport` проверяет только алфавит значения. `ICON=portianer`
  метку поставит, а прокси на неизвестном имени свалится в угадывание по
  имени. То есть «не задано» ведёт себя предсказуемее, чем «задано с
  опечаткой», — сверяйте написание глазами (`mcpVscode` — с заглавной V).
- **Набор задаёт сборка кластера, не агента.** Обновили агента — иконок
  не прибавилось; их добавляет только пересборка веб-морды прокси.

### Формат apps.d — контракт для расширений

```
NAME=code-server
URI=https://127.0.0.1:9002
ICON=mcpVscode
```

Два обязательных ключа и один необязательный. Файл пропускается целиком
(с предупреждением в журнале), если:

- владелец не root, права шире `0644` или это символическая ссылка;
- есть другой ключ или строка не `KEY=VALUE` — разбор без `source`;
- `NAME` не метка DNS (`[a-z0-9-]`, из него строится адрес);
- `URI` не `http(s)://127.0.0.1|localhost|[::1][:порт][/путь]`;
- `ICON` не `[A-Za-z0-9._-]` (алфавит имён иконок, значение уходит в YAML);
- имя уже объявлено другим файлом (побеждает первый по алфавиту).

**Метку доступа объявление задать не может.** Приложение получает метки ноды
плюс `app=<NAME>`; кому оно видно, решает `TELEPORT_ENV` оператора. Единственная
метка, которую объявление задаёт само, — `teleport.icon`, и решением о доступе
она не является. Файл в `apps.d` не может открыть приложение чужому `env`.

Обратная сторона той же монеты: `teleport.icon` **нельзя** задать через
`TELEPORT_LABELS` — метки ноды и метка приложения лягут в один YAML-map, дубль
ключа, и `teleport.yaml` не разберётся. Поэтому ключ зарезервирован рядом
с `env`, `app` и `managed_by`.

https на петле публикуется с `insecure_skip_verify`: у code-server
сертификат mkcert на localhost, а на путь по петле снаружи не встать.

Изменение в `apps.d` подхватывает `bisquite-teleport-apps.path` — reload
агента без участия человека.

Что объявляет сегодня: `code-server` (с 1.1.0, `ICON=laptop` с 3.0.1),
`selkies` (с 2.1.0, `ICON=desktop` с 4.0.3).

## teleport.yaml

`/etc/teleport.yaml` генерируется на каждом старте службы из
`/etc/bisquite/teleport`, руками не правится. Перед генерацией `render` сверяет
весь файл ручек со схемой: правка руками с кавычкой или `$` — отказ старта, а
не испорченный YAML.

- `nodename` — `TELEPORT_NODENAME` или имя хоста;
- `join_params` — пока есть токен. `token` (тот же вид, что до 2.4.0; после
  регистрации блока нет — токен стёрт):

  ```yaml
    join_params:
      token_name: "<токен>"
      method: token
  ```

  `bound_keypair` до регистрации; после неё — без двух последних строк:

  ```yaml
    join_params:
      token_name: "<имя токена>"
      method: bound_keypair
      bound_keypair:
        registration_secret_path: "/var/lib/bisquite/teleport/registration-secret"
  ```

- `ssh_service.listen_addr: 127.0.0.1:3022` — наружу порт не нужен, SSH идёт
  через обратный туннель;
- метки ноды: `TELEPORT_LABELS`, `managed_by=bisquite-teleport-agent`, `env`;
- динамическая метка ноды `os_logins` (если `TELEPORT_OS_LOGINS=1`):

  ```yaml
    commands:
      - name: "os_logins"
        command: ["/usr/local/sbin/bisquite-teleport", "os-logins"]
        period: 5m0s
  ```

- приложение `<имя>-<нода>`, `public_addr: <имя>.<нода>.<хост прокси>`;
- метка `teleport.icon` приложения — только если иконку задали; иначе строки
  нет, и прокси угадывает сам;
- приложению на петле — `rewrite.headers: Host: <публичный адрес>`, как за
  любым обратным прокси. Teleport по умолчанию передаёт `Host 127.0.0.1:<порт>`,
  и приложения, сверяющие Origin WebSocket с `Host`, отвечают браузеру 403 —
  так было с Selkies. Приложениям оператора на других хостах `Host` не
  переписывается: там он может выбирать виртуальный хост.

## Файлы

| Путь | Права | Что |
|---|---|---|
| `/usr/local/bin/teleport` | 0755 | агент |
| `/usr/local/sbin/bisquite-teleport` | ссылка | CLI → `/opt/bisquite/teleport-agent/bisquite-teleport` |
| `/etc/bisquite/teleport/config` | 0600 | ручки (домен `teleport`, `bisquite-conf show teleport`) |
| `/opt/bisquite/knobs/teleport{,.apply}` | ссылки | схема и хук применения |
| `/etc/bisquite/teleport/apps.d/` | 0755 | объявления |
| `/etc/teleport.yaml` | 0600 | генерируется |
| `/var/lib/teleport/` | 0750 | регистрация агента; у `bound_keypair` — и связанный ключ (`proc/`) |
| `/var/lib/bisquite/teleport/` | 0700 | `rollback` прежней регистрации на время `join` |
| `/var/lib/bisquite/teleport/registration-secret` | 0600 | секрет `bound_keypair` до регистрации |
| `teleport.service` | | агент; включает `join` |
| `bisquite-teleport-apps.path` | | `apps.d` → reload |
| `bisquite-teleport-token.path` | | появился `host_uuid` → токен (`token`) или секрет регистрации (`bound_keypair`) стёрт |

## Диагностика

```bash
sudo bisquite-teleport status
journalctl -u teleport -f
getent hosts x.<нода>.teleport.<домен>   # DNS для адресов приложений
```
