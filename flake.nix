# SPDX-FileCopyrightText: © 2024 @_beho
# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-csv";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    # The toolchain is the official 0.17.0 release binary, packaged by the
    # overlay, rather than nixpkgs' Zig.
    zig = {
      url = "git+https://git.jcollie.dev/jeff/zig-overlay.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig,
      ...
    }:
    let
      platforms = [ "x86_64-linux" ];
      packages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = (function: nixpkgs.lib.genAttrs platforms (system: function (packages system)));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.reuse
            zig.packages.${pkgs.stdenv.hostPlatform.system}."0.17.0"
          ];
        };
      });
    };
}
