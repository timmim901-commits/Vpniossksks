# Orbit — VPN для iOS на ядре sing-box

Вкладки: **Узлы** (подключение, режимы, подписки, пинг), **Правила** (как в Shadowrocket), **Tailscale**, **Сайт** (WebView на ваш сайт), **Ещё** (DNS, MTU, журнал, просмотр конфига).

* Протоколы: VLESS (Reality, XTLS-Vision, WS/gRPC/HTTPUpgrade), VMess, Trojan, Shadowsocks, Hysteria2, TUIC, AnyTLS, SOCKS5, WireGuard (.conf). Любой другой outbound sing-box (ShadowTLS, Naive и т.д.) — вставкой JSON.
* Правила: DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-REGEX, IP-CIDR, SRC-IP-CIDR, GEOIP, GEOSITE, DST-PORT, NETWORK → PROXY / DIRECT / REJECT. Импорт списков в синтаксисе Shadowrocket/Surge/Clash. Режимы: по правилам / глобально / напрямую. Готовые наборы: локальные сети, «Россия напрямую», блок рекламы.
* Tailscale внутри того же туннеля (auth key, Headscale, exit node, subnet routes).
* Доп.: автоподбор узла (urltest), проверка пинга, трафик в реальном времени, On Demand, QR-импорт, журнал ядра.

## Как собрать (без Mac)

Нужен аккаунт GitHub. Репозиторий **публичный** — тогда сборка на macOS-раннерах бесплатна.

1. Создайте репозиторий и загрузите туда содержимое этой папки (вместе с `.github`).
2. При желании поменяйте `BASE_BUNDLE_ID` и `APP_GROUP_ID` в `project.yml` (по умолчанию `com.timmim.vpn` и `group.com.timmim.vpn`).
3. На вкладке **Actions** запустите **Build Orbit IPA** (Run workflow). Первый раз сборка ядра идёт ~15–25 мин, потом берётся из кэша.
4. Готовый файл — в артефакте `Orbit-ipa`.

### Подпись (два варианта)

**А. Подпись прямо в CI (надёжнее).** В [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list):

1. Создайте App Group `group.com.timmim.vpn`.
2. Создайте два App ID: `com.timmim.vpn` и `com.timmim.vpn.tunnel`. У обоих включите **App Groups** (выберите вашу группу), у обоих — **Network Extensions**.
3. Создайте два Development- или Ad Hoc-профиля (для приложения и для туннеля) с вашим сертификатом и вашим устройством. Скачайте оба `.mobileprovision`.
4. Экспортируйте сертификат с закрытым ключом в `.p12`.
5. В репозитории: Settings → Secrets and variables → Actions → добавьте секреты (значения в base64: `base64 -i файл | pbcopy`):
   * `CERT_P12_BASE64`, `CERT_PASSWORD`
   * `APP_PROFILE_BASE64` — профиль основного приложения
   * `TUNNEL_PROFILE_BASE64` — профиль туннеля
6. Запустите workflow заново — получите `Orbit-signed.ipa`, его можно ставить на устройство из профиля (AltStore/Sideloadly/Apple Configurator/Xcode Devices).

**Б. Без секретов.** Получите `Orbit-unsigned.ipa` (внутри entitlements) и переподпишите Feather/Sideloadly. Важно: для туннеля нужен профиль с Network Extensions для `com.timmim.vpn.tunnel` — не каждый переподписчик умеет подписывать расширение своим профилем, так что вариант А надёжнее.

## Ссылки и логи

* Приложение открывает ссылки `sub://…` (base64 от URL подписки, как в Shadowrocket), `orbit://import?url=…`, `clash://install-config?url=…`, `sing-box://import-remote-profile?url=…`, `shadowrocket://add/sub://…`, а также `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `tuic://` — и сами добавляют подписку/узел. Те же ссылки можно вставить кнопкой «+» → «Вставить из буфера».
* **Ещё → Логи и отчёт**: логи приложения, туннеля и ядра (хранятся в файлах, переживают падения) и кнопка «Скопировать отчёт» — версии, состояние, хвосты логов и конфиг без секретов.

## Первый запуск

1. Откройте приложение → «+» → вставьте ссылку/подписку.
2. Нажмите кнопку питания, согласитесь на добавление VPN-конфигурации.
3. Для Tailscale: вкладка Tailscale → включить → вставить auth key (Settings → Keys в админке Tailscale).

## Устройство проекта

* `App/` — SwiftUI-приложение, `ConfigBuilder.swift` собирает JSON для sing-box, `LinkParser.swift` разбирает ссылки.
* `Tunnel/` — Packet Tunnel Extension (адаптирован из [sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple)). Читает `config.json` из App Group; по сообщению `reload` перечитывает.
* `.github/workflows/build.yml` — собирает `Libbox.xcframework` (gomobile) из зафиксированного коммита sing-box и IPA.
* Версия ядра зафиксирована (`SING_BOX_REF` в workflow), потому что API libbox меняется; Swift-код туннеля согласован именно с ней.

## Известные ограничения

* iOS ограничивает память расширения (~50 МБ): очень большие наборы правил/много узлов в `urltest` могут её превысить.
* Не поддерживаются: VLESS XHTTP (нет в sing-box), Clash YAML-подписки (только ссылки/base64/sing-box JSON), MITM/скрипты, правила по процессам (iOS не даёт).
* Проект не компилировался на Mac при создании — если сборка упадёт, пришлите лог шага «Собрать (без подписи)».

Лицензия: производная от sing-box / sing-box-for-apple → **GPL-3.0**; при раздаче приложения исходники должны быть доступны.

## Протоколы, редактор и пинг

- Поддерживаются: VLESS, VMess, Trojan, Shadowsocks, **ShadowTLS** (ss `shadow-tls=` или отдельное звено), Hysteria v1/v2, TUIC, AnyTLS, **HTTP/SOCKS5 (+TLS)**, Naive, SSH, **Snell**, WireGuard, **MASQUE**, **OpenConnect**, **OpenVPN**, Tailscale.
- **Relay** — «Цепочки» на главном экране: звенья идут по порядку (через `detour`).
- **Редактор JSON**: свайп по узлу → «JSON», либо «+» → шаблон / новый узел. «Ещё → Расширенное → Свой JSON-конфиг» подменяет весь конфиг.
- **Пинг**: без VPN — TCP до сервера (UDP-протоколы помечаются «UDP»), с VPN — реальный HTTP-тест через ядро. Свайп вправо по узлу — пинг одного.
- Не поддерживаются ядром sing-box: Sudoku, TrustTunnel, Mieru, Brook, Freedom (Lua), VLESS XHTTP.
