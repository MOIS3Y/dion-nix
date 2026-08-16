{
  description = "Dion desktop client package for Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      package = pkgs.callPackage ./default.nix { };
      app = {
        type = "app";
        program = pkgs.lib.getExe package;
        meta.description = package.meta.description;
      };
    in
    {
      packages.${system} = {
        dion = package;
        default = package;
      };

      apps.${system} = {
        dion = app;
        default = app;
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.deadnix
          pkgs.nixfmt
          pkgs.statix
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
