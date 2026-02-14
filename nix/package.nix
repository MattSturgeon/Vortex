{
  lib,
  cacert,
  clangStdenv,
  electron_42-bin,
  fetchPnpmDeps,
  fontconfig,
  jq,
  librsvg,
  makeBinaryWrapper,
  node-gyp,
  nodejs_24,
  pkg-config,
  pnpmConfigHook,
  pnpm_11,
  pnpmBuildHook,
  python3,
  stdenvNoCC,
  versionCheckHook,
}:
let
  electron = electron_42-bin;
  nodejs = nodejs_24;
  pnpm = pnpm_11;
in

clangStdenv.mkDerivation (finalAttrs: {

  __structuredAttrs = true;
  strictDeps = true;

  pname = "vortex";
  # TODO: where is release-version tracked?
  # TODO: get unstable-date from flake's sourceInfo
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset =
      let
        predicate = file: !file.hasExt "nix";
      in
      lib.fileset.intersection (lib.fileset.gitTracked ../.) (lib.fileset.fileFilter predicate ../.);
  };

  # TODO: Switch to importPnpmLock to avoid keeping hash in sync
  # NOTE: importPnpmLock relies on IFD, which can slow down eval
  # - https://tangled.org/scrumplex.net/importPnpmLock.nix
  # - https://github.com/Scrumplex/importPnpmLock.nix
  pnpmDeps = fetchPnpmDeps {
    inherit pnpm;
    inherit (finalAttrs)
      pname
      version
      src
      pnpmBuildScript
      pnpmInstallFlags
      ;
    # https://nixos.org/manual/nixpkgs/unstable/#javascript-pnpm-fetcherVersion
    fetcherVersion = 4;
    hash = "sha256-XrIMsuLlnlWoRWLNucQERHffX9Pbi5+dHmIrz2NLQ+w=";
  };

  # FIXME: download-duckdb-extensions does not use pinned URLs, so this is not reproducible and we will see hash mismatches.
  # Ideally, duckdb-extensions.json would list version-specific URLs _and_ the expected digest so that we can `fetchurl` them individually.
  duckdbExtensions = stdenvNoCC.mkDerivation {
    __structuredAttrs = true;
    strictDeps = true;

    pname = finalAttrs.pname + "-duckdb-extensions";
    inherit (finalAttrs) version src pnpmDeps;
    outputHash = "sha256-LZkR9l1YA3vZVAktwqc6o19uC0d+MYPJxunZNgia+7U=";
    outputHashMode = "recursive";

    nativeBuildInputs = [
      cacert
      nodejs
      jq
      pnpm
      pnpmConfigHook
    ];

    buildPhase = ''
      runHook preBuild
      pnpm tsx src/main/download-duckdb-extensions.ts
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      dest=$(jq --raw-output .outputDir src/main/duckdb-extensions.json)
      mv "src/main/$dest" "$out"
      runHook postInstall
    '';
  };

  env = {
    NX_NATIVE_COMMAND_RUNNER = "false";
    NODE_PATH = "${node-gyp}/lib/node_modules";

    # Prevent electron-builder from downloading Electron binaries
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

    # Point to Nix-provided Electron
    # TODO: does this replace the need for jqInPlace?
    ELECTRON_OVERRIDE_DIST_PATH = "${electron.dist}";
  };

  pnpmBuildScript = "package:nosign";
  pnpmInstallFlags = [
    "--ignore-scripts"
  ];

  nativeBuildInputs = [
    pnpmConfigHook
    pnpmBuildHook

    jq
    makeBinaryWrapper
    node-gyp # For font-scanner
    nodejs
    pnpm

    # For node-gyp
    pkg-config
    (python3.withPackages (ps: [ ps.setuptools ]))
  ];

  buildInputs = [
    # For font-scanner, used by theme-switcher
    fontconfig
  ];

  runtimeInputs = [
    nodejs
  ];

  runtimeEnv = {
    # Production mode
    NODE_ENV = "production";

    # GDK pixbuf loaders (for image loading)
    GDK_PIXBUF_MODULE_FILE = "${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";

    # Chromium sandbox
    CHROME_DEVEL_SANDBOX = "${electron}/libexec/electron/chrome-sandbox";
  };

  makeWrapperArgs = [
    "--inherit-argv0"

    # Runtime PATH
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath finalAttrs.runtimeInputs)
  ]
  # Runtime env
  ++ lib.foldlAttrs (
    acc: name: value:
    acc
    ++ [
      "--set"
      name
      (if lib.isBool value then lib.optionalString value "1" else value)
    ]
  ) [ ] finalAttrs.runtimeEnv;

  postPatch = ''
    # Install pre-fetched duckdb-extensions
    mkdir -p src/main/build
    duckdbExtensionsDest=$(jq --raw-output .outputDir src/main/duckdb-extensions.json)
    ln -s "$duckdbExtensions" "src/main/$duckdbExtensionsDest"

    substituteInPlace flatpak/com.nexusmods.vortex.desktop \
      --replace-fail run.sh vortex

    jqInPlace() {
      local file="$1"
      shift
      local tmp=$(mktemp)
      jq "$@" "$file" > "$tmp" && mv -f "$tmp" "$file"
    }

    jqInPlace src/main/electron-builder.config.json \
      --arg dist ${electron.dist} \
      --arg version ${electron.version} \
      '.electronDist = $dist | .electronVersion = $version'

    # FIXME: This is not enough. `pnpm deploy` still fails with:
    # > nx run @vortex/main:publish
    #
    # $ pnpm exec rimraf ./dist && pnpm cross-env pnpm_config_inject_workspace_packages=true pnpm_config_node_linker=hoisted pnpm -F @vortex/main deploy --offline --frozen-lockfile ./dist && node ./dist/prepare-dist-package.mjs
    # Packages are cloned from the content-addressable store to the virtual store.
    #   Content-addressable store is at: /build/tmp.86PUYz3un9/v11
    #   Virtual store is at:             dist/node_modules/.pnpm
    # dist                                     |    +1000 ++++++++++++++++++++++++++++
    # dist                                     | Progress: resolved 0, reused 1, downloaded 0, added 0
    # [WARN] Deployment with a shared lockfile has failed. If this is a bug, please report it at <https://github.com/pnpm/pnpm/issues>.
    # As a workaround, add the following to pnpm-workspace.yaml:
    #   forceLegacyDeploy: true
    # dist                                     | Progress: resolved 0, reused 900, downloaded 0, added 954
    # [ERR_PNPM_NO_OFFLINE_TARBALL] A package is missing from the store but cannot download it in offline mode. The missing package may be downloaded from https://codeload.github.com/Nexus-Mods/node-nexus-api/tar.gz/99a97cd1359527dbf5c46c93723d1846538badfe.
    # [ELIFECYCLE] Command failed with exit code 1.
    #
    #  NX   Ran target package:nosign for project @vortex/main and 153 task(s) they depend on (43s)
    #
    # Could be related to: https://github.com/pnpm/pnpm/issues/5315
    substituteInPlace src/main/package.json \
      --replace-fail 'deploy ./dist' 'deploy --offline --frozen-lockfile ./dist'
  '';

  buildPhase = ''
    runHook preBuild

    # Manually build font-scanner, required by theme-switcher
    # FIXME: the pnpm build system should be configured to do this
    pushd node_modules/.pnpm/font-scanner*/node_modules/font-scanner
    node-gyp rebuild --release
    popd

    pnpmBuildHook

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/lib"

    # Install the launcher, desktop file, icon, and metainfo into the Flatpak image.
    # install -Dm755 flatpak/run.sh /app/bin/run.sh
    install -Dm644 flatpak/com.nexusmods.vortex.desktop /app/share/applications/com.nexusmods.vortex.desktop
    install -Dm644 assets/images/vortex.png "$out/share/icons/hicolor/256x256/apps/com.nexusmods.vortex.png"
    # install -Dm644 flatpak/com.nexusmods.vortex.metainfo.xml /app/share/metainfo/com.nexusmods.vortex.metainfo.xml

    # Stage the built electron distribution into /app/main for runtime.
    install -d "$out/main"
    cp -a dist/linux*-unpacked/. "$out/main/"

    # FIXME: add conditional --download flag
    makeWrapper ${lib.getExe electron} "$out/bin/vortex"  \
      --add-flag "$out/main/vortex" \
      "''${makeWrapperArgs[@]}"

    runHook postInstall
  '';

  # doInstallCheck = true;
  nativeInstallCheckInputs = [
    versionCheckHook
  ];

  meta = {
    description = "The current mod manager from Nexus Mods";
    homepage = "https://github.com/Nexus-Mods/Vortex";
    longDescription = ''
      Vortex is the current mod manager from Nexus Mods.
      It is designed to make modding your game as simple as possible for new users, while still providing enough control for more experienced veterans of the modding scene.
    '';
    license = lib.licenses.gpl3Only;
    mainProgram = "vortex";
    # TODO: should this package list windows if the nix build isn't tested on windows?
    platforms = lib.platforms.linux ++ lib.platforms.windows;
  };
})
