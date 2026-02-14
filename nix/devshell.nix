{
  vortex,
  appstream,
  chromium,
  clang,
  dconf,
  dotnetCorePackages,
  electron_42-bin,
  flatpak,
  flatpak-builder,
  gitMinimal,
  glib,
  gnumake,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  librsvg,
  llvmPackages,
  mkShellNoCC,
}:
mkShellNoCC {
  inputsFrom = [
    vortex
  ];
  packages = [
    # Flatpak tooling
    flatpak
    flatpak-builder
    appstream

    # Build tools
    gitMinimal
    gnumake

    # C/C++ toolchain
    clang
    llvmPackages.libcxx

    # Dotnet
    dotnetCorePackages.sdk_9_0

    # Electron (wrapped with GTK dependencies)
    electron_42-bin

    # Playwright on NixOS uses Nix-provided Chromium instead of
    # downloaded browser binaries, which are not patched for NixOS.
    chromium

    # GTK dependencies for Electron runtime
    gtk3
    gtk4
    glib
    gsettings-desktop-schemas
    dconf
    librsvg
  ];

  env = {
    # Compiler settings for node-gyp
    CC = "${clang}/bin/clang";
    CXX = "${clang}/bin/clang++";

    # Ignore strict node engine version checks for legacy yarn tasks
    YARN_IGNORE_ENGINES = "true";

    # Prevent yarn from downloading Electron binaries
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

    # Point to Nix-provided Electron
    ELECTRON_OVERRIDE_DIST_PATH = "${electron_42-bin.dist}";

    # Point E2E auth-browser launches at Nix-provided Chromium.
    # Do not use `playwright install --with-deps` on NixOS; it tries apt-get.
    E2E_PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH = "${chromium}/bin/chromium";

    # Avoid Playwright host dependency checks. Nix supplies runtime deps.
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";

    # Make the dotnet runtime available
    DOTNET_ROOT = "${dotnetCorePackages.runtime_9_0}/share/dotnet";
  };

  # Set up GTK environment (mimics wrapGAppsHook3)
  shellHook = ''
    # GSettings schemas
    export XDG_DATA_DIRS="${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}:${gtk3}/share/gsettings-schemas/${gtk3.name}:${gtk4}/share/gsettings-schemas/${gtk4.name}:${glib}/share:$XDG_DATA_DIRS"

    # GIO modules (for dconf)
    export GIO_EXTRA_MODULES="${dconf.lib}/lib/gio/modules"

    # GDK pixbuf loaders (for image loading)
    export GDK_PIXBUF_MODULE_FILE="${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"

    # Chromium sandbox
    export CHROME_DEVEL_SANDBOX="${electron_42-bin}/libexec/electron/chrome-sandbox"

  '';
}
