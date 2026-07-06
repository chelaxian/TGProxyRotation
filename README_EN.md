# 🛡 TGProxyRotation

🌐 **[Читать на русском](README.md)**

[![Build](https://github.com/chelaxian/TGProxyRotation/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/chelaxian/TGProxyRotation/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/chelaxian/TGProxyRotation?include_prereleases)](https://github.com/chelaxian/TGProxyRotation/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

**Automatic proxy rotation for Telegram on iOS** — a feature that exists on Android, PC, and Mac, but for some reason is missing on iOS.

The tweak automatically switches between proxies you've already saved in Telegram when the current one goes down. No more manually diving into settings and cycling through proxies — if one stops responding, the tweak silently switches to the next working one.

<p align="center">
  <img alt="image1" src="https://github.com/user-attachments/assets/01f997ed-2756-428f-a665-92483884e94e" width="48%" />
  <img alt="image2" src="https://github.com/user-attachments/assets/95b23863-f7b5-41f1-b0a0-6885f346b722" width="48%" />
</p>

---

## ✨ Features

- 🔄 **Round-robin auto-switching** when the current proxy goes down
- ⏱️ **Configurable wait interval**: 5 / 10 / 15 / 30 / 60 sec
- ⬅️➡️ **Manual switching with arrows** (long press — random proxy)
- 📋 **Long press on `proxy:port`** — opens Telegram's native dialog to add the proxy to the client's saved list (stored locally)
- 🌐 **External proxy list via URL** (your own URL, `txt`: one `tg://proxy` or `https://t.me/proxy` per line) — the list is cached and loaded instantly on launch
- ✅ Shows **active proxy, ping, and countdown** to next switch
- ℹ️ **Long press the ⓘ icon** (at the top center of the tweak window) — toggle hint labels on/off for a cleaner interface
- 🇷🇺🇬🇧 UI in **Russian and English**
- 🚫 **Disable proxy** button (direct connection)

## 📱 Supported Clients

The tweak is **client-agnostic**: the injection filter hooks the `MTContext` class from **MTProtoKit**, not a specific bundle id. That's why it works out of the box with any MTProtoKit-based Telegram client that stores its account DB at the standard `telegram-data/accounts-metadata` path:

| Client | Bundle ID |
|---|---|
| Telegram (official) | `ph.telegra.Telegraph` |
| Swiftgram | `app.swiftgram.ios` |
| Nicegram / Turrit | `com.seastar.turrit` |
| Any other MTProtoKit fork | — |

The target client and its app-group container are resolved at runtime from the process's own entitlements — nothing is hardcoded.

## 🪟 How to Invoke the Tweak Window

While in Telegram, use any of these methods:

- 👆 **Long press** (~0.5 sec) anywhere on screen — e.g. on the native shield icon, the "Proxy" section in Settings, the "Proxy" text in the proxy list, or the 📎 Attachment icon in any chat
- ✋ **Three-finger tap** on the screen
- 🛡 Tap the **tweak's shield icon** that appears over Telegram after launch

## 📖 How to Use

1. Open the tweak window using any method above
2. Enable the **"Auto-switch proxy"** toggle
3. Choose an interval (10–15 sec is optimal)
4. Want a ready-made proxy list from the internet? Enable **"External proxy list"**; long press that toggle to set your own URL
5. The ← → arrows switch proxies manually; long press an arrow for a random pick
6. The **"−"** button minimizes the window into a shield, **"×"** closes it

> ⚠️ **Important:** the tweak **does not move the checkmark** in Telegram's native proxy list — switching happens under the hood (this was the only way to implement it reliably). Which proxy is currently active is always visible in the tweak window. In Telegram's built-in "Proxy" settings, the visually active proxy remains whatever was set before the tweak took over.

---

## 📦 Installation

> ⚠️ Download the file that matches your installation method. Rootless and RootHide are **different deb files**, because RootHide runs the binary through an on-device patcher at install time (rewrites rpath, re-signs for arm64e/PAC), while regular rootless installers don't.

### Option 1 — APT Repository (RootHide Bootstrap / Sileo)

Add the repository `https://ios.ratu.sh` and install the `TGProxyRotation` package:
```
https://ios.ratu.sh
```
RootHide Bootstrap will automatically determine which variant is needed and patch the binary during installation.

### Option 2 — Manual deb

Pick the file for your jailbreak:

| File | For |
|---|---|
| `*-rootless.deb` | **Rootless** jailbreaks: Dopamine, palera1n rootless, NathanLR, NekoJB |
| `*-roothide.deb` | **RootHide Bootstrap** (includes `.roothidepatch` sentinel and `arm64e` architecture) |

Download from the [latest Release](https://github.com/chelaxian/TGProxyRotation/releases/latest) and install via Sileo / Filza.

<details>
<summary>📦 Older versions (for rollback)</summary>

| Version | rootless deb | roothide deb | sideload dylib |
|---|---|---|---|
| **1.0.0** | [rootless.deb](https://github.com/chelaxian/TGProxyRotation/releases/download/v1.0.0/TGProxyRotation-1.0.0-rootless.deb) | [roothide.deb](https://github.com/chelaxian/TGProxyRotation/releases/download/v1.0.0/TGProxyRotation-1.0.0-roothide.deb) | [dylib](https://github.com/chelaxian/TGProxyRotation/releases/download/v1.0.0/TGProxyRotation-1.0.0.dylib) |
| **0.15.1** | [rootless.deb](https://github.com/chelaxian/TGProxyRotation/releases/download/v0.15.1/TGProxyRotation-0.15.1-rootless.deb) | [roothide.deb](https://github.com/chelaxian/TGProxyRotation/releases/download/v0.15.1/TGProxyRotation-0.15.1-roothide.deb) | [dylib](https://github.com/chelaxian/TGProxyRotation/releases/download/v0.15.1/TGProxyRotation-0.15.1.dylib) |
| **0.15.0** | [rootless.deb](https://github.com/chelaxian/TGProxyRotation/releases/download/v0.15.0/TGProxyRotation-0.15.0-rootless.deb) | [roothide.deb](https://github.com/chelaxian/TGProxyRotation/releases/download/v0.15.0/TGProxyRotation-0.15.0-roothide.deb) | — |

</details>

### Option 3 — Sideload dylib (NO jailbreak)

For injection via **Sideloadly** or **TrollFools** into the Telegram IPA:
- 📥 [TGProxyRotation-1.0.2.dylib](https://github.com/chelaxian/TGProxyRotation/releases/download/v1.0.2/TGProxyRotation-1.0.2.dylib)
- 🕓 [TGProxyRotation-1.0.0.dylib](https://github.com/chelaxian/TGProxyRotation/releases/download/v1.0.0/TGProxyRotation-1.0.0.dylib) (old)
- 🕓 [TGProxyRotation-0.15.1.dylib](https://github.com/chelaxian/TGProxyRotation/releases/download/v0.15.1/TGProxyRotation-0.15.1.dylib) (old)

---

## 🔧 Requirements

- **iOS 15.0+**
- One of the following:
  - **RootHide Bootstrap** (arm64e, on-device patching), or
  - **rootless jailbreak** (Dopamine / palera1n rootless, etc.), or
  - **sideload** via Sideloadly / TrollFools / TrollStore (no jailbreak)

## 🏗 Building from Source

You need [Theos](https://theos.dev) and `iPhoneOS16.5.sdk`.

```bash
# RootHide/rootless deb
export THEOS="$HOME/theos"
gmake clean package FINALPACKAGE=1
# → packages/com.ratush.tgproxyrotation_<version>_iphoneos-arm64e.deb

# Sideload dylib (no MobileSubstrate dependency)
gmake -f Makefile.dylib clean
gmake -f Makefile.dylib FINALPACKAGE=1
# → .theos/obj/TGProxyRotation.dylib
```

Or use the local helper (WSL/Ubuntu): `bash build.sh`

Ready-made artifacts are always available in [**Releases**](https://github.com/chelaxian/TGProxyRotation/releases/latest) — built automatically via GitHub Actions from the same source.

---

## 🧩 How It Works (brief)

1. **Reading the proxy list** — from Telegram's Postbox SQLite (`accounts-metadata/db/db_sqlite`, key `0x00000004`, Codable `ProxySettings` struct). Host/port/secret are parsed from the binary blob.
2. **Applying a proxy** — via `MTContext` hook → `updateApiEnvironment:` → `withUpdatedSocksProxySettings:`. Passing `nil` disables the proxy.
3. **"Proxy alive" signal** — `reportTransportSchemeSuccessForDatacenterId:` (success) / `reportTransportSchemeFailureForDatacenterId:` (failure).
4. **TCP ping** — non-blocking `connect()` + `poll()` with a 2s timeout, as an independent health check.
5. **Phantom tick at startup** — `gStartupPending` suppresses the phantom first rotation by applying the saved proxy (`TGRotateBy(0)`) instead of rotating forward.

See [`Tweak.x`](Tweak.x) for implementation details.

## 📜 License

[GPL-3.0](LICENSE) © chelaxian

## 🔗 Links

- 🌐 Tweaks repository + website: [ios.ratu.sh](https://ios.ratu.sh)
- 💬 Author: [@chelaxian](https://github.com/chelaxian)
