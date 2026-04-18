{
  description = "batmon: Linux laptop power monitoring TUI in Zig";

  inputs = {
    # As of April 17, 2026, Zig 0.16.0 and zls_0_16 have landed on nixpkgs master.
    # Track master here so flake.lock can pin a commit that definitely contains them.
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";

    # Previous Zig master path kept for reference.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    # zls-src = {
    #   url = "github:zigtools/zls";
    #   flake = false;
    # };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        # pkgs = import nixpkgs {
        #   inherit system;
        # };
        # zig = pkgs.zig_0_16;
        zls = pkgs.zls_0_16;

        # Previous Zig master path kept for reference.
        overlays = [ inputs.zig-overlay.overlays.default ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        # zig = pkgs.zigpkgs.master;
        zig = pkgs.zigpkgs."0.16.0";

        # zlsDeps = pkgs.callPackage "${zls-src}/deps.nix" {};
        # zls = pkgs.stdenvNoCC.mkDerivation {
        #   pname = "zls";
        #   version = "master-${zls-src.shortRev or "unknown"}";
        #   src = zls-src;
        #   nativeBuildInputs = [ zig ];
        #   postPatch = ''
        #     substituteInPlace build.zig.zon \
        #       --replace-fail '.minimum_zig_version = "0.16.0",' '.minimum_zig_version = "${zig.version}",'
        #   '';
        #   buildPhase = ''
        #     zig build install \
        #       --system ${zlsDeps} \
        #       --global-cache-dir "$TMPDIR/zig-cache" \
        #       --prefix "$out" \
        #       --color off
        #   '';
        #   installPhase = ":";
        # };
        packageNativeBuildInputs = [
          pkgs.pkg-config
          zig
          zig.hook
        ];
        commonBuildInputs = [ pkgs.sqlite ];
      in
      {
        packages.batmon = pkgs.stdenv.mkDerivation {
          pname = "batmon";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = packageNativeBuildInputs;
          buildInputs = commonBuildInputs;
          postInstall = ''
            mkdir -p $out/share/doc/batmon $out/lib/systemd/system
            cp README.md AGENTS.md $out/share/doc/batmon/
            cp packaging/batmond.service $out/lib/systemd/system/
          '';
        };

        packages.batmond = self.packages.${system}.batmon;
        packages.zls = zls;
        packages.default = self.packages.${system}.batmon;

        apps.default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.batmon;
          exePath = "/bin/batmon";
        };

        checks.default = pkgs.stdenv.mkDerivation {
          pname = "batmon-check";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = packageNativeBuildInputs;
          buildInputs = commonBuildInputs;
          buildPhase = ''
            zig build test-compile
          '';
          installPhase = ''
            mkdir -p $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.pkg-config
            pkgs.sqlite
            zig
            zls
          ];
        };
      }
    )
    // {
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.batmon;
        in
        {
          options.services.batmon = {
            enable = lib.mkEnableOption "batmon collector";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.batmon;
            };
            databasePath = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/batmon/batmon.db";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.batmon = {
              description = "batmon power collector";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];
              serviceConfig = {
                ExecStart = "${cfg.package}/bin/batmond run --database-path ${cfg.databasePath}";
                Restart = "always";
                RestartSec = 2;
                StateDirectory = "batmon";
                WorkingDirectory = "/var/lib/batmon";
                User = "root";
              };
            };
          };
        };
    };
}
