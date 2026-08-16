{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  dpkg,
  makeWrapper,
  alsa-lib,
  at-spi2-atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gnutls,
  gtk3,
  libappindicator,
  libgbm,
  libGL,
  libnotify,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,
  xdg-utils,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "dion";
  version = "5.34.0";

  src = fetchurl {
    url = "https://static.dion.vc/desktop_app/dion_${finalAttrs.version}_amd64.deb";
    hash = "sha256-cnu6wsD1/Hx6FDpk6wYgPv8eBaQjW/hynLvAK7KvbjQ=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libgbm
    libsecret
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    pango
  ];

  runtimeDependencies = map lib.getLib [
    libappindicator
    libGL
    libnotify
    libsecret
    pipewire
    systemd
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --extract "$src" .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/opt" "$out/bin"
    cp -r opt/Dion "$out/opt/Dion"
    cp -r usr/share "$out/share"

    makeWrapper "$out/opt/Dion/dion" "$out/bin/dion" \
      --inherit-argv0 \
      --prefix XDG_DATA_DIRS : "$GSETTINGS_SCHEMAS_PATH" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libGL ]} \
      --suffix PATH : ${
        lib.makeBinPath [
          gnutls
          xdg-utils
        ]
      } \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations,WebRTCPipeWireCapturer --enable-wayland-ime=true}}"

    substituteInPlace "$out/share/applications/dion.desktop" \
      --replace-fail "/opt/Dion/dion" "dion"

    runHook postInstall
  '';

  meta = {
    description = "Desktop client for Dion video conferencing";
    homepage = "https://dion.vc/";
    license = lib.licenses.unfree;
    mainProgram = "dion";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
