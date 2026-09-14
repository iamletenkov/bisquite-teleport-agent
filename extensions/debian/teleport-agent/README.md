# teleport-agent

Агент Teleport на машине: SSH-нода и веб-приложения, без входящих портов —
агент сам держит обратный туннель к прокси на 443.

Образ **нейтрален к кластеру**: на сборке ставятся бинарь, CLI и юниты, а
адрес кластера, `env` и токен задаются на устройстве одной командой. Один
образ подключается к разным кластерам и `env`, и переезд — та же команда.

Разбор решений — спека bisquite `docs/specs/2026-09-14-teleport-agent.md`.
Совместим со стеком `teleport-keycloak-ldap`: форма `teleport.yaml` та же, что
у его install.sh, так что роль `smart_role`, список нод в админке и адреса
приложений `<app>.<нода>.teleport.<домен>` работают без правок стека.

## Сборка

```
EXTENSION teleport-agent TELEPORT_VERSION=18.6.8 \
    TELEPORT_MIRROR=https://binaries.example.org
```

| Параметр | Умолчание | Что делает |
|---|---|---|
| `TELEPORT_VERSION` | `18.6.8` | версия агента; **не новее кластера**, не старше на мажор |
| `TELEPORT_MIRROR` | пусто | зеркало бинарей стека (`…/binaries/teleport/<версия>/…`); пусто — `cdn.teleport.dev` |
| `TELEPORT_SHA256` | пусто | хеш tarball; пусто — `.sha256` с `cdn.teleport.dev` (второй канал, если tarball с зеркала) |

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
| `TELEPORT_TOKEN` | да | токен или `-` (stdin) |
| `TELEPORT_ENV` | фактически да | метка `env`: по ней `smart_role` даёт доступ; без неё ноду видят только `access`/`editor` |
| `TELEPORT_CA_PIN` | нет | `sha256:…` из `tctl status`; у прокси с публичным сертификатом TLS проверяется и без него |
| `TELEPORT_NODENAME` | нет | по умолчанию короткое имя хоста (из cloud-init) |
| `TELEPORT_LABELS` | нет | `site=lab,robot=orin`; ключи `env`, `app`, `managed_by` — отказ |
| `TELEPORT_FORCE` | нет | `1` — переподключиться к тому же кластеру заново |

Что делает `join`, по порядку:

1. **Уже зарегистрирован в этом же прокси** — ничего не стирает, применяет
   метки и выходит. Повтор `runcmd` (клон носителя, `cloud-init clean`) не
   убивает рабочую ноду просроченным токеном из seed.
2. **Предпроверка до остановки агента:** `https://<прокси>/webapi/find` с
   проверкой TLS, версия агента против `server_version`. Если машина была
   зарегистрирована, недоступный прокси — отказ, прежнее подключение цело.
   Если не была (первая загрузка, сети ещё нет) — предупреждение: агент
   стартует и повторяет попытки сам.
3. Прежнее состояние — в `/var/lib/bisquite-teleport/rollback`, чистый
   `/var/lib/teleport` (кешированная CA прежнего кластера иначе даёт
   `no authorities for hostname`), конфиг, старт.
4. Ждёт `host_uuid` до 120 с (`BISQUITE_TELEPORT_JOIN_TIMEOUT`). Не дождался,
   а прежняя регистрация была — **возвращает её** и завершается ошибкой.

### set

`TELEPORT_ENV`, `TELEPORT_NODENAME`, `TELEPORT_LABELS`, `TELEPORT_APPS`,
`TELEPORT_APPS_DISABLE`, `TELEPORT_APPS_DISCOVERY`, `TELEPORT_CA_PIN`.
Применяет к работающему агенту через reload (HUP — мягкий перезапуск Teleport,
открытые SSH-сессии живут). `TELEPORT_PROXY` и `TELEPORT_TOKEN` — только `join`.

### leave

Запись ноды в кластере сама не удаляется — у ноды нет на это прав. Она
исчезнет по истечении heartbeat, либо удаляется в админке.

## Приложения

Два источника и один выключатель:

| Откуда | Кто пишет | Адрес |
|---|---|---|
| `/etc/bisquite/teleport/apps.d/<имя>.conf` | расширения на сборке | только петля |
| `TELEPORT_APPS=имя=порт,имя=URI` | оператор | любой; `порт` — `http://127.0.0.1:<порт>` |
| `TELEPORT_APPS_DISABLE=имя,…` | оператор | не публиковать |

Одно имя в обоих — побеждает `TELEPORT_APPS`. `TELEPORT_APPS_DISCOVERY=0`
игнорирует `apps.d` целиком.

### Формат apps.d — контракт для расширений

```
NAME=code-server
URI=https://127.0.0.1:9002
```

Ровно два ключа. Файл пропускается целиком (с предупреждением в журнале), если:

- владелец не root, права шире `0644` или это символическая ссылка;
- есть другой ключ или строка не `KEY=VALUE` — разбор без `source`;
- `NAME` не метка DNS (`[a-z0-9-]`, из него строится адрес);
- `URI` не `http(s)://127.0.0.1|localhost|[::1][:порт][/путь]`;
- имя уже объявлено другим файлом (побеждает первый по алфавиту).

**Меток в объявлении нет по построению.** Приложение получает метки ноды плюс
`app=<NAME>`; кому оно видно, решает `TELEPORT_ENV` оператора. Файл в
`apps.d` не может открыть приложение чужому `env`.

https на петле публикуется с `insecure_skip_verify`: у code-server
сертификат mkcert на localhost, а на путь по петле снаружи не встать.

Изменение в `apps.d` подхватывает `bisquite-teleport-apps.path` — reload
агента без участия человека.

Что объявляет сегодня: `code-server` (с 1.1.0).

## teleport.yaml

`/etc/teleport.yaml` генерируется на каждом старте службы из
`/etc/bisquite/teleport`, руками не правится:

- `nodename` — `TELEPORT_NODENAME` или имя хоста;
- `ssh_service.listen_addr: 127.0.0.1:3022` — наружу порт не нужен, SSH идёт
  через обратный туннель;
- метки ноды: `TELEPORT_LABELS`, `managed_by=bisquite-teleport-agent`, `env`;
- приложение `<имя>-<нода>`, `public_addr: <имя>.<нода>.<хост прокси>`.

## Файлы

| Путь | Права | Что |
|---|---|---|
| `/usr/local/bin/teleport` | 0755 | агент |
| `/usr/local/sbin/bisquite-teleport` | 0755 | CLI |
| `/etc/bisquite/teleport/config` | 0600 | ручки |
| `/etc/bisquite/teleport/apps.d/` | 0755 | объявления |
| `/etc/teleport.yaml` | 0600 | генерируется |
| `/var/lib/teleport/` | 0750 | регистрация агента |
| `teleport.service` | | агент; включает `join` |
| `bisquite-teleport-apps.path` | | `apps.d` → reload |
| `bisquite-teleport-token.path` | | появился `host_uuid` → токен стёрт |

## Диагностика

```bash
sudo bisquite-teleport status
journalctl -u teleport -f
getent hosts x.<нода>.teleport.<домен>   # DNS для адресов приложений
```
