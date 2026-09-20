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

### IMPLEMENTED 2026-09-20 (Ryzen) — 19 lines, 3 files

The flag lives in the **conditional-import pair**, not in `common.dart`, because
that is the existing seam for "this value depends on the platform":
`native/common.dart` has `dart:io`, `web/common.dart` does not.

`flutter/lib/native/common.dart`:

```dart
const _kForceMobileUiDefine =
    bool.fromEnvironment('RUSTDESK_FORCE_MOBILE_UI', defaultValue: false);
final forceMobileUi_ = Platform.isLinux &&
    (_kForceMobileUiDefine ||
        Platform.environment['RUSTDESK_MOBILE_UI'] == '1');
```

`flutter/lib/web/common.dart`: `final forceMobileUi_ = false;`

`flutter/lib/common.dart:58,64`:

```dart
final forceMobileUi = forceMobileUi_;
final isDesktop = isDesktop_ && !forceMobileUi;
var isMobile = isAndroid || isIOS || forceMobileUi;
```

**Two ways to turn it on**, so one binary serves both cases:

| Mechanism | Use |
|---|---|
| `RUSTDESK_MOBILE_UI=1` env var | runtime, flip it on any build without rebuilding |
| `--dart-define=RUSTDESK_FORCE_MOBILE_UI=true` | compile-time, for a dedicated phone package |

Guarded by `Platform.isLinux`, so a stray env var cannot flip a Windows or macOS
user into the mobile UI.

**`isDesktop_` deliberately keeps its old meaning** — "this OS is a desktop OS",
still true on a PinePhone. Only `isDesktop` ("use the desktop UI") changes. Code
that legitimately needs the OS family is therefore untouched by the opt-in.

### Audit results — the override cannot be bypassed

Checked on the real tree, not assumed:

- **`isDesktop_` is referenced in exactly one place** outside its two
  definitions: `common.dart:58`. Nothing reaches around the override.
- **`isMobile` is never reassigned anywhere.** It is declared `var`, but the
  mutability is vestigial — the only assignment is its initialiser.
- **`runMobileApp()` (`main.dart:176`) is already platform-neutral.** Its only
  Android-specific calls, `androidChannelInit()` and
  `syncAndroidServiceAppDirConfigPath()`, are *already* wrapped in
  `if (isAndroid)`. Everything else it touches — `initEnv`, `checkUpdate`,
  `draggablePositions`, the `gFFI` models, `runApp(App())`, `initUniLinks` — is
  shared code. **The entry path needs no changes at all.**
- **`mobile/` contains zero `MethodChannel`, Android-intent or permission
  calls.** The Android plumbing lives in `common/` and `native/` behind guards.
  Only 31 `isAndroid`/`isIOS` refs across 8 files in `mobile/`, all conditionals
  that take the else branch on Linux.

Net: the mobile tree is markedly less Android-coupled than this plan assumed.
The remaining work is where the plan already said it was — input handling.

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

### Getting the source — clone recursively

`libs/hbb_common` is a **git submodule**. A plain `git clone` leaves it empty and
the build dies well into the run, at the cargo step, with a message that names
the workspace member rather than the submodule:

```
error: failed to load manifest for workspace member `libs/scrap`
  ... failed to read `libs/hbb_common/Cargo.toml`
  ... No such file or directory (os error 2)
```

So clone with `--recursive`, or repair an existing clone:

```bash
git submodule update --init --recursive
```

On a minimal rootfs also `apt install --no-install-recommends gettext-base`, or
every `git submodule` call prints `gettext: not found` / `envsubst: not found`.
Harmless, but it buries real output.

## Ryzen — primary (do the work here)

**Environment built 2026-09-20.** Host is `megatron` (Ryzen 7 5700X, 8c/16t,
63.9 GB). WSL2 2.7.14.0, kernel 6.18.33.2, distro `rustdesk-dev`, repo at
`/home/arthur/dev/rustdesk`.

Four things about this setup are not obvious and cost time:

**1. Do not use the Store's Debian — it is bookworm (12), not trixie (13).**
The phone runs trixie, and the whole point of matching Debian versions is ABI
parity with the target. Import a trixie rootfs instead:

```bash
# from Windows
curl -o rootfs.tar.xz https://images.linuxcontainers.org/images/debian/trixie/amd64/default/<build>/rootfs.tar.xz
wsl --import rustdesk-dev F:\wsl\rustdesk-dev F:\wsl\images\rootfs.tar.xz --version 2
```

**2. Put the distro on the big drive.** `wsl --import` takes the target path, so
point it at whichever disk has room. A vcpkg tree that builds aom, libvpx and
ffmpeg from source plus a Rust `target/` will not fit in a typical C: remainder.
This machine: C: had 65 GB free, F: had 606 GB, so the distro lives on F:.

**3. WSL only gets half the host RAM by default**, which would be 32 GB here —
under the 64 GB the "stock `lto = true` links fine" note assumes. Set it
explicitly in `%USERPROFILE%\.wslconfig`, then `wsl --shutdown`:

```ini
[wsl2]
memory=48GB
processors=16
swap=8GB
```

**4. A backgrounded process dies when the `wsl.exe` handle closes.** `nohup`,
`setsid` and `disown` do not save it — a 693 MB Flutter download was reaped this
way. Long jobs must run in the foreground of a `wsl.exe` invocation that stays
alive for their duration.

Two more, if you drive WSL from Git Bash rather than PowerShell: an unquoted
`/home/...` argument gets path-translated into `C:/Program Files/Git/home/...`
(use `MSYS_NO_PATHCONV=1`, or keep the command inside `bash -c '...'`), and a
`<<"EOF"` heredoc loses its quoting in transit, so `$VAR` and `$(cmd)` expand on
the *Windows* side. Write scripts to a file and copy them in; do not pipe a
heredoc through `wsl.exe`.

Editing the WSL tree from Windows tooling works fine over
`\\wsl.localhost\rustdesk-dev\home\arthur\dev\rustdesk\...`.

Deps are upstream's own `Dockerfile` list, **plus autotools, which that list
omits** — see below. Install both together:

```bash
sudo apt update && sudo apt install --no-install-recommends -y \
  g++ gcc git curl nasm yasm libgtk-3-dev clang libxcb-randr0-dev libxdo-dev \
  libxfixes-dev libxcb-shape0-dev libxcb-xfixes0-dev libasound2-dev libpulse-dev \
  make wget libssl-dev unzip zip libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev ca-certificates ninja-build cmake python3 \
  pkg-config xz-utils \
  autoconf automake libtool autoconf-archive
```

**Upstream's dependency list is incomplete: `mfx-dispatch` needs `autoconf`.**
Without it `vcpkg install` dies partway with

```
CMake Error at scripts/cmake/vcpkg_configure_make.cmake:721 (message):
  mfx-dispatch requires autoconf from the system package manager
```

which is easy to misread as a vcpkg problem rather than a missing apt package.
It is worse than it looks, because vcpkg **stops at that point**, so `opus` —
which comes after it in the order — is never built either, and `vcpkg list`
then shows a plausible-looking set of packages with two quietly absent. Check
for `opus` and `mfx-dispatch` by name before trusting a vcpkg run.

This will hit the Mac container identically; same Debian base, same port.

Note: upstream's Dockerfile compiles CMake 3.30.6 from source. Skip it —
trixie ships 3.31.6. Confirmed 2026-09-20: trixie gives cmake 3.31.6,
gcc 14.2.0, clang 19.1.7, python 3.13.5, git 2.47.3, ninja 1.12.1.

On a minimal container rootfs this list pulls a large GTK/GStreamer dependency
chain and takes a while. That is expected, not a hang.

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
- [x] Ryzen environment built — WSL2 trixie on F:, deps + Rust 1.75 in
- [x] `forceMobileUi` flag implemented — 19 lines, 3 files, uncommitted
- [x] Override audited for bypass — none; entry path needs no changes
- [ ] Toolchain finished (Flutter 3.24.5 + vcpkg still installing on Ryzen)
- [ ] `flutter analyze` clean
- [ ] Mobile UI renders on x86_64 Linux
- [ ] Input handling adapted for touch
- [ ] arm64 Flutter SDK solved
- [ ] Installs and runs on PinePhone Pro

**Last updated 2026-09-20 by the Ryzen machine.** Next action here: finish the
toolchain, `flutter analyze`, then a first `python3 ./build.py --flutter
--hwcodec` and run it with `RUSTDESK_MOBILE_UI=1` to see what the mobile tree
does on a desktop Linux target.

Nothing is required of the Mac or the phone yet. The arm64 Flutter SDK is still
the open blocker for deployment and is still correctly scheduled last — it gates
shipping, not development.
