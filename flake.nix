{
  description = "Rios de Asia accounting";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # `pm`, the project manager CLI, in the dev shell
    pm = {
      url = "github:rubenmoor/project-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, pm }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in {
      packages = forAll (system: pkgs: {
        default = pkgs.python3Packages.buildPythonApplication {
          pname = "rios-de-asia-accounting";
          version = "0.1.0";
          pyproject = true;
          src = ./.;
          build-system = [ pkgs.python3Packages.setuptools ];
          dependencies = with pkgs.python3Packages; [ flask jinja2 waitress ];
          nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
          meta.mainProgram = "rios-de-asia-accounting";
        };
      });

      apps = forAll (system: pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/rios-de-asia-accounting";
        };
      });

      checks = forAll (system: pkgs: {
        backup-module =
          let
            os = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  services.rios-de-asia-accounting-backup = {
                    enable = true;
                    backupDir = "/tmp/bk";
                    keep = 7;
                    dbPath = "/tmp/books.db";
                    onCalendar = "03:00";
                  };
                  boot.loader.grub.enable = false;
                  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
                  system.stateVersion = "25.05";
                }
              ];
            };
            svc = os.config.systemd.user.services.rios-de-asia-accounting-backup;
            timer = os.config.systemd.user.timers.rios-de-asia-accounting-backup;
            exe = "${self.packages.${system}.default}/bin/rios-de-asia-accounting";
            ok = svc.serviceConfig.Type == "oneshot"
              && svc.serviceConfig.ExecStart
                == "${exe} --db /tmp/books.db backup --backup-dir /tmp/bk --keep 7"
              && timer.timerConfig.OnCalendar == "03:00"
              && timer.timerConfig.Persistent == true
              && timer.wantedBy == [ "timers.target" ];
          in
          assert ok;
          pkgs.runCommand "rios-de-asia-accounting-backup-module" { } "touch $out";
        default = self.packages.${system}.default;
        lint = pkgs.runCommand "rios-de-asia-accounting-lint" { nativeBuildInputs = [ pkgs.ruff ]; } ''
          cd ${./.}
          export RUFF_CACHE_DIR=$TMPDIR/ruff
          ruff check src tests
          ruff format --check src tests
          touch $out
        '';
      });

      nixosModules.default = import ./nix/module.nix { inherit self; flavor = "nixos"; };
      homeManagerModules.default = import ./nix/module.nix { inherit self; flavor = "home-manager"; };

      devShells = forAll (system: pkgs: {
        default = pkgs.mkShell {
          packages = [
            # first, so `python` is the one with the libraries, not a bare one pulled in by pm
            (pkgs.python3.withPackages (ps: [ ps.flask ps.jinja2 ps.waitress ps.pytest ]))
            pm.packages.${system}.default
            pm.packages.${system}.dashboard
            pkgs.git
            pkgs.ruff
            pkgs.sqlite
          ];
        };
      });
    };
}
