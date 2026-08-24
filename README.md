# OUM — OpenWrt Ultimate Manager

Интерактивный менеджер для профессиональной настройки роутеров OpenWrt.
Одно меню вместо десятков мануалов: обход блокировок, NAS, оптимизация,
диагностика, бэкапы.

```
==================================================
       OUM v7.3 — OpenWrt Ultimate Manager
==================================================
Podkop ●  Zapret ○  Watchdog ●  QUIC-block ●  NAS ●

1) Интернет и обход блокировок (Podkop, Zapret, AWG, GearUP, QUIC)
2) Сеть и Wi-Fi
3) Производительность (аппаратное ускорение)
4) NAS и медиа
5) Система (драйверы, темы LuCI)
6) Диагностика и обслуживание (бэкапы, обновление, удаление)
7) Быстрый статус
8) Установить команду oum (запуск без пути + CLI)
```

## Установка

SSH на роутер, затем:

```sh
wget -O /tmp/oum.sh https://raw.githubusercontent.com/ShockioOcki/oum/main/oum.sh
sh /tmp/oum.sh
```

Или одной командой:

```sh
sh <(wget -O - https://raw.githubusercontent.com/ShockioOcki/oum/main/oum.sh)
```

В меню: пункт 8 — установить как команду `oum` (плюс CLI-режим и
самообновление).

## Возможности

- **Интернет и обход блокировок**: Podkop (+ watchdog v3 с каскадом
  восстановления и тестом), Zapret через Zapret-Manager (всегда свежая
  версия с GitHub), AmneziaWG,
  GearUP, блокировка QUIC (совместима с Zapret-Manager), GitHub
  hosts-fix с авто-применением при недоступности GitHub
- **Сеть и Wi-Fi**: SSID/пароль, IPv6, Wi-Fi powersave fix
- **Производительность**: software/hardware flow offloading с детектом
  чипсета и FIX совместимости с DPI-обходом (offload после 30 пакетов)
- **NAS и медиа**: SMB (ksmbd), aria2 + AriaNg, медиа-сортировщик
  (сериалы/фильмы, русские названия через TMDB)
- **Система**: драйверы USB/ФС под конкретные модели (AX6S, RAX3000M,
  TR3000, BPI-R3), темы LuCI (Proton2025, Argon, Material)
- **Диагностика**: 12 проверок («почему не работает»), включая конфликты
  Podkop+Zapret, offloading без FIX, рассинхрон времени
- **Бэкапы**: в persistent-хранилище (переживают перезагрузку), ротация,
  восстановление через sysupgrade
- **CLI-режим**: `oum status | oum diag | oum log [N] | oum version`
- **Самообновление**: проверка и обновление из этого репозитория

## CLI

```sh
oum status    # дашборд одним выводом
oum diag      # полная диагностика
oum log 50    # последние 50 записей лога
oum version   # версия
```

## Поддерживаемые пакеты-менеджеры

opkg (OpenWrt 21–23) и apk (OpenWrt 24+). Определяется автоматически.

## Ветки

- `main` — стабильная версия (рекомендуется для роутеров)
- `dev` — ветка разработки

## Благодарности

- [Podkop](https://github.com/itdoginfo/podkop) — itdoginfo
- [Zapret-Manager](https://github.com/StressOzz/Zapret-Manager) — StressOzz
  (FIX flow offloading, идея hosts-fix, QUIC-блок)
- [AWG OpenWrt](https://github.com/Slava-Shchipunov/awg-openwrt) — Slava-Shchipunov
- [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon) — jerrykuku
