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
