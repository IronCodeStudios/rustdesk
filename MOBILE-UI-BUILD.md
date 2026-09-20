# Mobile UI on ARM Linux phones — build plan

Shared instruction for all three machines. Pull this branch, read your section.

## Goal

RustDesk on a Linux phone (PinePhone / PinePhone Pro, Librem 5, postmarketOS
devices) installs the **desktop** build, because the OS is desktop Linux. But the
screen is a phone. The desktop GUI is unusable at that size.

The mobile Flutter UI already ships in this repo — `flutter/lib/mobile/`. It is
selected by a platform check, not by screen size. This change lets a Linux build
**opt into** that existing UI.

Not a port. No second UI tree. No new widgets.

## Design

`flutter/lib/main.dart:45` dispatches on one flag:

```dart
if (!isDesktop) {
  runMobileApp();
  return;
}
```

`flutter/lib/common.dart:58,64` define it:

```dart
final isDesktop = isDesktop_;
var isMobile = isAndroid || isIOS;
```

The change is to make those two respect an opt-in override:

```dart
final isDesktop = isDesktop_ && !_forceMobileUi;
var isMobile = isAndroid || isIOS || _forceMobileUi;
```

Every one of the **140** `isDesktop` references in shared code
(`common.dart`, `models/`, `common/`, `utils/`) then follows automatically.

Opt-in, so existing desktop users see no change. That is the whole argument for
upstream merge.

### Where the real work is

Ranked by `isDesktop` density in shared code:

| File | refs | governs |
|---|---|---|
| `common.dart` | 33 | the flag, layout/theme helpers |
| `models/model.dart` | 26 | core session state |
| `common/widgets/peer_card.dart` | 14 | peer list — the main screen |
| `models/relative_mouse_model.dart` | 10 | pointer translation |
| `models/input_model.dart` | 10 | keyboard/mouse input |
| `common/widgets/toolbar.dart` | 10 | in-session toolbar |
| `common/widgets/remote_input.dart` | 7 | touch vs mouse input |

**43 of those refs are input handling.** That is the substance: mobile assumes
touch, desktop assumes pointer + keyboard. On a Linux phone you want touch.

`models/server_model.dart` has only **2** — the connection-manager split is in
the process-launching layer, not the model. Biggest de-risking fact we have.

### Known desktop-only paths that will need handling

- Multi-window sessions — `runMultiWindow`, `main.dart:188`. Mobile uses in-app
  tabs. `libdesktop_multi_window_plugin.so` is compiled in.
- Connection manager runs as a **separate process** (`kAppTypeConnectionManager`,
  `--cm`). Mobile handles it in-process. Matters if the phone accepts incoming
  connections.
- Tray / autostart / service integration.

## Device roles

| Machine | Role |
|---|---|
| **Ryzen 7, 64 GB, Win11** | Primary dev + build, in WSL2 or a Linux VM. x86_64. |
| **MacBook Air M1, 8 GB** | arm64 Linux container. Produces the phone binary. |
| **PinePhone Pro** | Test target. Install and run only. |

**The UI change is architecture-independent.** Develop and validate the whole
thing on x86_64, where the official Flutter SDK works. arm64 is only needed for
the binary that installs on the phone.

## Ryzen — primary (do the work here)

WSL2 Debian trixie, or a VM. Deps are upstream's own `Dockerfile` list:

```bash
sudo apt update && sudo apt install --no-install-recommends -y \
  g++ gcc git curl nasm yasm libgtk-3-dev clang libxcb-randr0-dev libxdo-dev \
  libxfixes-dev libxcb-shape0-dev libxcb-xfixes0-dev libasound2-dev libpulse-dev \
  make wget libssl-dev unzip zip libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev ca-certificates ninja-build cmake python3 \
  pkg-config xz-utils
```

Note: upstream's Dockerfile compiles CMake 3.30.6 from source. Skip it —
trixie ships 3.31.6.

Versions pinned by upstream CI (`.github/workflows/flutter-build.yml`):

- Flutter **3.24.5** (Dart 3.5.4)
- Rust **1.75**
- vcpkg commit **9e593bb18ea69cc5095e012465dcd675a822ed0d**

```bash
# Flutter (x86_64 host - official SDK, works)
curl -LO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz
tar xf flutter_linux_3.24.5-stable.tar.xz && export PATH="$PWD/flutter/bin:$PATH"

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
rustup toolchain install 1.75 && rustup default 1.75

# vcpkg
git clone https://github.com/microsoft/vcpkg && cd vcpkg
git checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d
./bootstrap-vcpkg.sh -disableMetrics && export VCPKG_ROOT="$PWD" && cd ..
$VCPKG_ROOT/vcpkg install --x-install-root="$VCPKG_ROOT/installed"

# build
python3 ./build.py --flutter --hwcodec
```

64 GB means the stock `[profile.release]` (`lto = true`, `codegen-units = 1`)
links fine. No workaround needed here.

## Mac M1 — arm64 binary only

Native arm64 Linux container, so no emulation:

```bash
docker run -it --rm -v "$PWD:/src" -w /src debian:trixie-slim
```

Same base as the phone (Debian 13), so the output installs directly. Same dep
list as above.

**8 GB is tight for the final link.** Use thin LTO:

```bash
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
```

Prefer OrbStack over Docker Desktop — less VM overhead on 8 GB.

### OPEN BLOCKER — arm64 Flutter SDK

Flutter publishes **no arm64 Linux SDK**. Verified against the release manifest:
0 of 171 stable Linux releases are arm64.

Upstream defines `FLUTTER_ELINUX_VERSION: "3.16.9"` with the comment *"for arm64
linux because official Dart SDK does not work"* — but that variable is
**unused** in the current workflows, and the Linux jobs are gone from `ci.yml`.
The documented path is stale.

It is definitely solvable: the shipping `rustdesk` 1.4.9 arm64 `.deb` is a real
Flutter build (`lib/libflutter_linux_gtk.so`, `data/flutter_assets`) reporting
Dart 3.5.4 = Flutter 3.24.5. Someone builds this. The recipe is not public.

Options, cheapest first:
1. `flutter-elinux` 3.16.9, as the stale variable suggests.
2. A community arm64 Dart/Flutter SDK.
3. GitHub Actions on an arm64 Linux runner.

**Solve this last.** It gates deployment, not development.

## PinePhone Pro — test target

```bash
sudo apt install --no-install-recommends ./rustdesk-<ver>-aarch64.deb
```

Constraints that have already bitten:
- 3.8 GB RAM. Never build here.
- **Always** `--no-install-recommends`; `xdg-utils` alone pulled 52 packages and died.
- IPv6 is broken on this carrier. `~/.ssh/config` forces `AddressFamily inet`.
- Never run interactive prompt-driven commands here; they look identical to hangs.

## Branches

| Branch | Contents |
|---|---|
| `master` | clean mirror of upstream `rustdesk/rustdesk` |
| `fix/linux-arm64-flutter-bundle-path` | 1 commit, upstreamable on its own |
| `feat/mobile-ui-on-linux` | this plan + the UI work |

Keep the `build.py` fix separate — it stands alone and merges without the UI
argument.

Fork was reset to upstream `97811acbd` on 2026-09-20. PR #15063 (Wayland
videoconvert) is already upstream as `377547fa1`; nothing was lost.

## Status

- [x] Fork synced to current upstream
- [x] `build.py` arm64 bundle path fixed
- [x] Shared code mapped (140 refs)
- [ ] Ryzen environment built
- [ ] `_forceMobileUi` flag implemented
- [ ] Mobile UI renders on x86_64 Linux
- [ ] Input handling adapted for touch
- [ ] arm64 Flutter SDK solved
- [ ] Installs and runs on PinePhone Pro
