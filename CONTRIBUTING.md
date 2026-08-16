# Contributing to dion-nix

Contributions that improve the package, documentation, or support for new
Dion releases are welcome. Keep the package native to Nix and avoid FHS
compatibility environments unless upstream makes that strictly necessary.

This guide documents how the current package was investigated, why its
dependencies are present, how to test changes, and how to update Dion.

## Development

The package is intentionally implemented as a normal derivation. It does not
use `buildFHSEnv`, `steam-run`, or another FHS compatibility environment. The
official Debian archive is unpacked, its ELF files are patched for Nix, and a
small launcher supplies dependencies that Electron discovers only at runtime.

### Development Tools

Enter the development shell:

```console
nix develop
```

It provides `nixfmt`, `statix`, and `deadnix`. Run all project checks with:

```console
nixfmt --check default.nix flake.nix
statix check .
deadnix --fail .
nix flake check
nix build --print-build-logs
```

Open a temporary shell with the additional tools used during package analysis:

```console
nix shell \
  nixpkgs#binutils \
  nixpkgs#dpkg \
  nixpkgs#file \
  nixpkgs#jq \
  nixpkgs#patchelf
```

The tools have the following roles:

- `dpkg-deb` reads package metadata and extracts the Debian archive.
- `file` distinguishes ELF programs and libraries from application data.
- `readelf` displays dynamic ELF metadata, including `DT_NEEDED` entries.
- `patchelf` displays and changes interpreters, dependencies, and RPATHs.
- `jq` extracts the store path and hash from Nix JSON output.

Format and evaluate the current package with:

```console
nix fmt -- --check flake.nix default.nix
nix flake check
nix build --print-build-logs
```

### Fetching the Upstream Package

Start with the exact upstream URL. Pinning a versioned archive is preferable
to using a mutable `latest` URL:

```console
version=5.34.0
url="https://static.dion.vc/desktop_app/dion_${version}_amd64.deb"
nix store prefetch-file "$url" --json
```

The command downloads the archive into the Nix store and prints output similar
to:

```json
{
  "hash": "sha256-...",
  "storePath": "/nix/store/...-dion_5.34.0_amd64.deb"
}
```

Copy the SRI `hash` value into the `fetchurl` block in `default.nix`. The hash
makes the source immutable and causes the build to fail if the server replaces
the file without changing its versioned URL.

Store the path in a shell variable when inspecting the archive:

```console
deb=$(nix store prefetch-file "$url" --json | jq -r .storePath)
```

### Inspecting Debian Metadata

Read the control metadata before deciding which files and dependencies to
package:

```console
dpkg-deb --info "$deb"
dpkg-deb --field "$deb" Package Version Architecture Depends Recommends
```

For Dion 5.34.0, the important metadata is:

- package name: `dion`;
- Debian version: `5.34.0-4407`;
- architecture: `amd64`;
- installed program directory: `/opt/Dion`;
- desktop integration directory: `/usr/share`.

The Nix package uses the public application version `5.34.0`, because that is
the version present in the download URL. The Debian build suffix can still be
recorded when it becomes relevant to distinguishing upstream rebuilds.

Inspect maintainer scripts as well. They can reveal configuration files,
services, permissions, or mutable filesystem operations that should not run in
a Nix build:

```console
work=$(mktemp -d)
dpkg-deb --control "$deb" "$work/control"
sed -n '1,240p' "$work/control/postinst"
sed -n '1,240p' "$work/control/postrm"
```

Dion's scripts optionally manage `/etc/dion/dion-startup-policy.json`. The Nix
package does not execute these scripts: writing `/etc` is not appropriate while
building an immutable user application. The feature can be modeled separately
as a NixOS module if managed startup policy is needed later.

### Inspecting the Archive Layout

Extract the payload into a temporary directory:

```console
root="$work/root"
mkdir -p "$root"
dpkg-deb --extract "$deb" "$root"
find "$root" -maxdepth 5 -type f -print | sort
```

The relevant parts of the Dion archive are:

```text
opt/Dion/                         Electron application and resources
usr/share/applications/dion.desktop
usr/share/icons/hicolor/          Application icons
usr/share/mime/packages/dion.xml  MIME type definitions
```

The install phase copies `/opt/Dion` and `/usr/share` into the output. It also
replaces `/opt/Dion/dion` in the desktop entry with `dion`, allowing desktop
environments to find the launcher through `PATH` instead of an FHS path.

### Finding ELF Dependencies

The Debian `Depends` field is useful, but it is not a complete specification
for Nix packaging. Distribution package names differ from Nixpkgs attributes,
Electron may bundle libraries, and some libraries are loaded dynamically.

List every ELF object and its direct dependencies:

```console
find "$root/opt/Dion" -type f -exec sh -c '
  file -b "$1" | grep -q ELF || exit 0
  echo "FILE: $1"
  patchelf --print-interpreter "$1" 2>/dev/null || true
  patchelf --print-needed "$1" 2>/dev/null || true
' sh {} \;
```

The same information can be inspected with `readelf`:

```console
readelf -d "$root/opt/Dion/dion" | grep NEEDED
```

`autoPatchelfHook` scans installed ELF files during the fixup phase. It changes
the glibc interpreter and adds store paths for matching libraries. A first
`nix build --print-build-logs` is therefore an effective dependency probe: the
build reports every direct library it cannot satisfy.

### Why These Dependencies Are Present

The direct ELF dependencies live in `buildInputs` so `autoPatchelfHook` can
find them:

| Input | Purpose |
| --- | --- |
| `alsa-lib` | Microphone, speaker, and Chromium audio support. |
| `at-spi2-atk` | GTK accessibility interfaces used by Electron. |
| `cairo`, `pango` | Text and 2D rendering for the GTK interface. |
| `cups` | Chromium printing support. |
| `dbus` | Desktop IPC, portals, notifications, and services. |
| `expat` | XML parsing required by Chromium. |
| `glib`, `gtk3` | Core event loop and desktop user interface. |
| `libgbm` | GPU buffer management used by Chromium. |
| `libx11`, `libxcb` | X11 client and transport libraries. |
| `libxcomposite` | Chromium compositing on X11. |
| `libxdamage` | X11 damage tracking for redraws. |
| `libxext`, `libxfixes` | X11 extension support. |
| `libxkbcommon` | Keyboard layout processing. |
| `libxrandr` | Display geometry and monitor handling. |
| `nspr`, `nss` | Chromium networking, TLS, and certificates. |
| `libsecret` | Desktop keyring integration. |

Some components are opened with `dlopen` or discovered by subprocesses. They
do not always appear in `DT_NEEDED`, so they are listed in
`runtimeDependencies`:

| Input | Runtime purpose |
| --- | --- |
| `libappindicator` | System tray indicator integration. |
| `libGL` | GLVND, OpenGL, and native EGL dispatch. |
| `libnotify` | Desktop notifications. |
| `libsecret` | Credentials stored through Secret Service. |
| `pipewire` | Wayland screen capture for WebRTC. |
| `systemd` | `libudev` device discovery used by Chromium. |

`runtimeDependencies` asks `autoPatchelfHook` to retain these library paths in
patched executables even when no direct ELF dependency points to them.

### Why the Launcher Is Required

`makeWrapper` creates `bin/dion` and supplies runtime details that cannot be
encoded entirely through direct ELF dependencies:

- `XDG_DATA_DIRS` exposes GTK and GSettings schemas.
- `PATH` includes `xdg-utils` for opening links and desktop integration.
- `PATH` includes GnuTLS because Dion invokes `p11tool` for certificates.
- Wayland flags are enabled when both `NIXOS_OZONE_WL` and
  `WAYLAND_DISPLAY` are present.
- `WebRTCPipeWireCapturer` enables screen sharing through PipeWire.

The launcher also adds the `libGL` directory to `LD_LIBRARY_PATH`. This is a
targeted workaround for Dion's bundled ANGLE library:

1. The main executable loads the bundled `opt/Dion/libEGL.so`.
2. That library calls `dlopen("libEGL.so.1")` to find native EGL.
3. ELF `RUNPATH` is not transitive, so the main executable's RPATH is not used
   for that nested lookup.
4. The launcher makes GLVND visible to Dion and its GPU subprocesses.

Without this step, the application window may open, but Chromium repeatedly
restarts its GPU process with `EGL_NOT_INITIALIZED` errors.

### X11, Wayland, and Screen Sharing

By default, Electron can continue to use X11 or XWayland. Native Wayland mode
is selected only when the user opts in with `NIXOS_OZONE_WL` and a Wayland
display is available:

```console
NIXOS_OZONE_WL=1 ./result/bin/dion
```

The wrapper then enables Ozone auto-detection, Wayland window decorations,
Wayland input methods, and the WebRTC PipeWire capturer. PipeWire and a working
desktop portal must also be configured by the host system. Packaging a client
library cannot configure the user's compositor or portal service.

### Testing a Build

First run the deterministic checks:

```console
nix fmt -- --check flake.nix default.nix
nix flake check
nix build --print-build-logs
```

Confirm that the desktop entry no longer contains an FHS executable path:

```console
grep '^Exec=' result/share/applications/dion.desktop
```

Inspect the generated wrapper and main RPATH when troubleshooting:

```console
sed -n '1,180p' result/bin/dion
nix shell nixpkgs#patchelf --command \
  patchelf --print-rpath result/opt/Dion/dion
```

Use a temporary profile for a launch test so development does not modify the
normal Dion configuration:

```console
smoke=$(mktemp -d)
mkdir -p "$smoke/config" "$smoke/cache"
XDG_CONFIG_HOME="$smoke/config" \
XDG_CACHE_HOME="$smoke/cache" \
timeout 60s ./result/bin/dion 2>&1 | tee "$smoke/launch.log"
```

Check the log for packaging failures:

```console
grep -E \
  'cannot open shared object|command not found|EGL_NOT_INITIALIZED' \
  "$smoke/launch.log"
```

An empty result is expected. Warnings about Electron listener counts,
deprecated Node.js APIs, updater support, or deep-link registration originate
upstream and do not by themselves indicate a packaging failure.

Finally, perform a real interactive test. Automated launch checks cannot prove
that desktop services are configured correctly. Verify at least:

- login and conference navigation;
- microphone input and speaker output;
- camera access;
- opening external links;
- notifications and the system tray;
- screen sharing on the target X11 or Wayland session.

### Updating Dion

To package a new upstream release:

1. Find the new versioned `amd64` Debian archive.
2. Change `version` in `default.nix`.
3. Prefetch the new URL and replace the `fetchurl` hash.
4. Inspect Debian metadata, layout, scripts, and ELF dependencies again.
5. Build with full logs and resolve any newly missing libraries.
6. Run the isolated smoke test and inspect its log.
7. Test audio, video, and screen sharing interactively.
8. Commit `default.nix` together with any changed documentation.

The typical update starts with:

```console
version=NEW_VERSION
url="https://static.dion.vc/desktop_app/dion_${version}_amd64.deb"
nix store prefetch-file "$url" --json
```

Then edit these attributes:

```nix
version = "NEW_VERSION";

src = fetchurl {
  url =
    "https://static.dion.vc/desktop_app/"
    + "dion_${finalAttrs.version}_amd64.deb";
  hash = "sha256-NEW_HASH";
};
```

Do not assume that only the version and hash changed. Electron upgrades can
add libraries, rename resources, change desktop entries, alter command-line
flags, or introduce native modules. Repeat the inspection steps for every
release and compare the archive with the previous version.

`flake.lock` pins Nixpkgs, not Dion. Update it separately when desired:

```console
nix flake update nixpkgs
nix flake check
nix build
```

Review Nixpkgs updates with the same runtime tests because Electron depends on
the behavior of graphics, GTK, PipeWire, NSS, and system libraries.

### Troubleshooting Checklist

When a future release builds but does not run, check in this order:

1. Search the launch log for a missing command or shared library.
2. Inspect `DT_NEEDED` and RPATH for every changed ELF file.
3. Search binaries for names such as `libsecret`, `libnotify`, or `pipewire`.
4. Determine whether the dependency is linked or loaded with `dlopen`.
5. Add linked libraries to `buildInputs`.
6. Add dynamically loaded libraries to `runtimeDependencies`.
7. Use a wrapper only for subprocess discovery or non-transitive lookups.
8. Rebuild and test with a new temporary configuration directory.

Avoid solving a single missing dependency by wrapping the entire application
in an FHS environment. A native derivation keeps dependencies explicit,
produces a smaller closure, and makes future failures easier to diagnose.

