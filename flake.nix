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
          pname = "airbnb-books";
          version = "0.1.0";
          pyproject = true;
          src = ./.;
          build-system = [ pkgs.python3Packages.setuptools ];
          dependencies = with pkgs.python3Packages; [ flask jinja2 waitress ];
          nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
          meta.mainProgram = "airbnb-books";
        };
      });

      apps = forAll (system: pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/airbnb-books";
        };
      });

      checks = forAll (system: pkgs: {
        default = self.packages.${system}.default;
        lint = pkgs.runCommand "airbnb-books-lint" { nativeBuildInputs = [ pkgs.ruff ]; } ''
          cd ${./.}
          export RUFF_CACHE_DIR=$TMPDIR/ruff
          ruff check src tests
          ruff format --check src tests
          touch $out
        '';
      });

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
