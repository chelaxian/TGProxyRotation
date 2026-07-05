# 🛡 TGProxyRotation

[![Build](https://github.com/chelaxian/TGProxyRotation/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/chelaxian/TGProxyRotation/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/chelaxian/TGProxyRotation?include_prereleases)](https://github.com/chelaxian/TGProxyRotation/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

**Автоматическая ротация прокси для Telegram на iOS** — функция, которая есть на Android, PC и Mac, но которой почему-то нет на iOS.

Твик сам переключает прокси из тех, что уже сохранены у тебя в Telegram, когда текущий отваливается. Больше не нужно вручную лезть в настройки и перебирать прокси — если один перестал отвечать, твик молча переключится на следующий рабочий.

<img width="640" height="591" alt="image" src="https://github.com/user-attachments/assets/01f997ed-2756-428f-a665-92483884e94e" /><img width="640" height="591" alt="image" src="https://github.com/user-attachments/assets/95b23863-f7b5-41f1-b0a0-6885f346b722" />

---

## ✨ Что умеет

- 🔄 **Автопереключение прокси по кругу**, когда связь пропадает
- ⏱️ **Настраиваемый интервал ожидания**: 5 / 10 / 15 / 30 / 60 сек
- ⬅️➡️ **Ручное переключение стрелками** (долгий тап — случайный прокси)
- 🌐 **Внешний список прокси по ссылке** (свой URL, `txt`: по одному `tg://proxy` или `https://t.me/proxy` на строку) — список кэшируется и подтягивается мгновенно при запуске
- ✅ Показывает **активный прокси, пинг и обратный отсчёт** до переключения
- 🇷🇺🇬🇧 Интерфейс **на русском и английском**
- 🚫 Кнопка **полного отключения прокси** (прямое соединение)

## 📱 Поддерживаемые клиенты

Твик **client-agnostic**: фильтр инъекции навешен на класс `MTContext` из **MTProtoKit**, а не на конкретный bundle id. Поэтому он работает из коробки с любым MTProtoKit-based клиентом Telegram, который хранит account-DB по стандартному пути `telegram-data/accounts-metadata`:

| Клиент | Bundle ID |
|---|---|
| Telegram (официальный) | `ph.telegra.Telegraph` |
| Swiftgram | `app.swiftgram.ios` |
| Nicegram / Turrit | `com.seastar.turrit` |
| Любой другой MTProtoKit-форк | — |

Поддерживаемый клиент и его app-group-контейнер определяются в рантайме из entitlements самого процесса — ничего не захардкожено.

## 🪟 Как вызвать окно твика

Находясь в Telegram, любым способом:

- 👆 **Долгий тап** (~0,5 сек) в любом месте экрана — например по штатной иконке-щиту, по разделу «Прокси» в Настройках, по тексту «Прокси» в списке прокси, по иконке 📎 Вложений в любом чате
- ✋ **Тап тремя пальцами** по экрану
- 🛡 Тап по **иконке-щиту твика**, которая появляется поверх Telegram после запуска

## 📖 Как пользоваться

1. Открой окно твика любым способом выше
2. Включи галочку **«Автопереключение прокси»**
3. Выбери интервал (10–15 сек — оптимально)
4. Хочешь готовый список прокси из интернета — включи **«Внешний список прокси»**; долгий тап по этой галчке позволяет задать свой URL
5. Стрелки ← → переключают прокси вручную; долгий тап по стрелке — случайный выбор
6. Кнопка **«−»** сворачивает окно в щит, **«×»** закрывает

> ⚠️ **Важно:** твик **не двигает галочку** в родном списке прокси Telegram — переключение происходит «под капотом» (не получилось иначе реализовать). Какой прокси активен сейчас — всегда видно в окне твика. В штатных настройках «Прокси» в Telegram визуально активным остаётся тот прокси, который был выставлен до твика.

---

## 📦 Установка

> ⚠️ Скачивай тот файл, который соответствует твоему способу установки. Rootless и RootHide — это **разные deb**, потому что RootHide при установке прогоняет бинарник через on-device patcher (переписывает rpath, пере-подписывает под arm64e/PAC), а обычные rootless-инсталлеры этого не делают.

### Вариант 1 — APT-репозиторий (RootHide Bootstrap / Sileo)

Добавь репозиторий `https://ios.ratu.sh` и установи пакет `TGProxyRotation`:
```
https://ios.ratu.sh
```
RootHide Bootstrap сам определит, какой вариант нужен, и пропатчит бинарник при установке.

### Вариант 2 — deb вручную

Выбери файл по своему джейлбрейку:

| Файл | Для |
|---|---|
| `*-rootless.deb` | **Rootless**-джейлбрейки: Dopamine, palera1n rootless, NathanLR, NekoJB |
| `*-roothide.deb` | **RootHide Bootstrap** (с `.roothidepatch` sentinel и архитектурой `arm64e`) |

Скачать из [последнего Release](https://github.com/chelaxian/TGProxyRotation/releases/latest) и установить через Sileo / Filza.

### Вариант 3 — sideload dylib (БЕЗ джейлбрейка)

Для инъекции через **Sideloadly** или **TrollFools** в IPA Telegram:
- 📥 [TGProxyRotation-0.15.0.dylib](https://ios.ratu.sh/sideload/TGProxyRotation-0.15.0.dylib)

---

## 🔧 Требования

- **iOS 15.0+**
- Один из способов запуска:
  - **RootHide Bootstrap** (arm64e, on-device patching), либо
  - **rootless jailbreak** (Dopamine / palera1n rootless и т.п.), либо
  - **sideload** через Sideloadly / TrollFools / TrollStore (без джейлбрейка)

## 🏗 Сборка из исходников

Нужен [Theos](https://theos.dev) и `iPhoneOS16.5.sdk`.

```bash
# RootHide/rootless deb
export THEOS="$HOME/theos"
gmake clean package FINALPACKAGE=1
# → packages/com.ratush.tgproxyrotation_<version>_iphoneos-arm64e.deb

# Sideload dylib (без зависимости от MobileSubstrate)
gmake -f Makefile.dylib clean
gmake -f Makefile.dylib FINALPACKAGE=1
# → .theos/obj/TGProxyRotation.dylib
```

Либо локальный хелпер (под WSL/Ubuntu): `bash build.sh`

Готовые артефакты всегда можно взять из [**Releases**](https://github.com/chelaxian/TGProxyRotation/releases/latest) — они собираются автоматически через GitHub Actions из этого же исходника.

---

## 🧩 Как это работает (коротко)

1. **Чтение списка прокси** — из Telegram Postbox SQLite (`accounts-metadata/db/db_sqlite`, ключ `0x00000004`, Codable-структура `ProxySettings`). Парсим host/port/secret из бинарного blob'а.
2. **Применение прокси** — через хук `MTContext` → `updateApiEnvironment:` → `withUpdatedSocksProxySettings:`. Передача `nil` отключает прокси.
3. **Сигнал «прокси жив»** — `reportTransportSchemeSuccessForDatacenterId:` (успех) / `reportTransportSchemeFailureForDatacenterId:` (провал).
4. **TCP-пинг** — неблокирующий `connect()` + `poll()` с таймаутом 2с, как независимый health-check.
5. **Phantom-tick при старте** — `gStartupPending` гасит фантомное первое вращение, применяя сохранённый прокси (`TGRotateBy(0)`) вместо rotate-forward.

Детали — в комментариях в [`Tweak.x`](Tweak.x).

## 📜 Лицензия

[GPL-3.0](LICENSE) © chelaxian

## 🔗 Ссылки

- 🌐 Репозиторий твиков + сайт: [ios.ratu.sh](https://ios.ratu.sh)
- 💬 Автор: [@chelaxian](https://github.com/chelaxian)
