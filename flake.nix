{
  description = "Tidarr: self-hosted Tidal downloader with a Lidarr-compatible provider (cstaelen/tidarr). Self-contained — bundles every program it shells out to.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus/flake-lib/v1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    # tiddl is Tidarr's download backend; consumed here so the root flake only depends on tidarr.
    tiddl.url = "github:jgus/tiddl-flake";
    tiddl.inputs.nixpkgs.follows = "nixpkgs";
    tiddl.inputs.flake-utils.follows = "flake-utils";
    tiddl.inputs.flake-lib.follows = "flake-lib";
  };

  outputs = { self, nixpkgs, flake-utils, flake-lib, tiddl }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pin = import ./pin.nix;
        inherit (pin) version sourceRev sourceHash yarnHash;
        pkgs = import nixpkgs { inherit system; };
        source = { type = "github"; owner = "cstaelen"; repo = "tidarr"; };

        src = pkgs.fetchFromGitHub {
          owner = "cstaelen";
          repo = "tidarr";
          rev = sourceRev;
          hash = sourceHash;
        };

        # beets is opt-in (ENABLE_BEETS); ship pylast/pillow so the lastgenre/fetchart/embedart plugins work if enabled.
        beetsWithPlugins = pkgs.beets.overridePythonAttrs (old: {
          dependencies = (old.dependencies or [ ]) ++ (with pkgs.python3Packages; [ pylast pillow requests ]);
        });

        # Everything the Express backend spawns at runtime (by bare name, via PATH). Bundled onto the
        # package's own PATH so the program is self-sufficient and the consumer only has to containerize it.
        runtimeDeps = [
          tiddl.packages.${system}.tiddl # the Tidal downloader
          beetsWithPlugins # `beet` (opt-in via ENABLE_BEETS)
          pkgs.rsgain # ReplayGain tagging (REPLAY_GAIN)
          pkgs.ffmpeg # tiddl audio post-processing
          pkgs.curl # ntfy/gotify/pushover/apprise notifications
          pkgs.coreutils # cp/rm/ls/chmod/chown in the move/clean pipeline
          pkgs.findutils # find in the move/clean pipeline
          pkgs.bash # the shell those commands run under
        ];

        # Offline yarn mirror for the (yarn-classic) workspace build.
        offlineCache = pkgs.fetchYarnDeps {
          yarnLock = src + "/yarn.lock";
          hash = yarnHash;
        };

        # Backend hardcodes the app tree at /tidarr; repoint it at the store install dir.
        installDir = "share/tidarr";

        tidarr = pkgs.stdenv.mkDerivation {
          pname = "tidarr";
          inherit version src offlineCache;

          nativeBuildInputs = [
            pkgs.nodejs
            pkgs.yarn
            pkgs.fixup-yarn-lock
            pkgs.makeWrapper
            pkgs.autoPatchelfHook # patch vite's prebuilt native .node (rolldown/lightningcss) for the build
          ];
          # libgcc_s.so.1 for the glibc native build tools; the musl-variant .node files are never loaded here.
          buildInputs = [ pkgs.stdenv.cc.cc.lib ];
          dontAutoPatchelf = true; # patched manually below, against the build tree (not $out)
          autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

          postPatch = ''
            substituteInPlace api/constants.ts \
              --replace-fail '"/tidarr"' "\"$out/${installDir}\""
            substituteInPlace api/index.ts \
              --replace-fail '"/tidarr/app/build"' "\"$out/${installDir}/app/build\""
          '';

          configurePhase = ''
            runHook preConfigure
            export HOME="$(mktemp -d)"
            yarn config --offline set yarn-offline-mirror "$offlineCache"
            fixup-yarn-lock yarn.lock
            yarn install --offline --frozen-lockfile --ignore-scripts --no-progress --non-interactive
            patchShebangs node_modules
            # vite loads prebuilt native binaries at build time; patch them before building.
            autoPatchelf node_modules
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            yarn --offline workspace tidarr-react run build
            yarn --offline workspace tidarr-api run build
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/${installDir}/api" "$out/${installDir}/app" "$out/${installDir}/docker" "$out/bin"
            cp -r api/dist "$out/${installDir}/api/dist"
            cp -r app/dist "$out/${installDir}/app/build"
            cp -r docker/settings "$out/${installDir}/docker/settings"

            # Production-only node_modules, mirroring upstream docker/Dockerfile's production stage:
            # a fresh tree with only the root + api manifests, then a --production install. This drops
            # the heavy dev/e2e deps (vite, typescript, playwright, testcontainers, monaco, ...).
            prod="$(mktemp -d)"
            cp package.json yarn.lock "$prod/"
            install -Dm644 api/package.json "$prod/api/package.json"
            ( cd "$prod"
              export HOME="$(mktemp -d)"
              yarn config --offline set yarn-offline-mirror "$offlineCache"
              fixup-yarn-lock yarn.lock
              yarn install --offline --frozen-lockfile --production --ignore-optional --ignore-scripts --no-progress --non-interactive
            )
            patchShebangs "$prod/node_modules"
            cp -r "$prod/node_modules" "$out/${installDir}/node_modules"
            [ -d "$prod/api/node_modules" ] && cp -r "$prod/api/node_modules" "$out/${installDir}/api/node_modules" || true

            makeWrapper ${pkgs.lib.getExe pkgs.nodejs} "$out/bin/tidarr" \
              --add-flags "$out/${installDir}/api/dist/index.js" \
              --chdir "$out/${installDir}" \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps} \
              --set-default VERSION "${version}" \
              --set-default PYTHONUNBUFFERED 1
            runHook postInstall
          '';

          # node_modules ships prebuilt JS; nothing further to fix up.
          dontStrip = true;

          meta.mainProgram = "tidarr";
        };

        update-version = flake-lib.lib.mkUpdateVersion {
          inherit pkgs source;
          buildAttr = "tidarr";
          # yarnHash is the offline-mirror hash of upstream yarn.lock at the pinned rev.
          extraHashes = [ "yarnHash" ];
          artifactHook = flake-lib.lib.mkJsDepsHook { inherit pkgs; manager = "yarn"; };
        };

        update-branches = flake-lib.lib.mkUpdateBranches {
          inherit pkgs source;
          pinSchema = "github-yarn";
        };
      in
      {
        packages = {
          inherit tidarr update-version update-branches;
          default = tidarr;
        };
      });
}
