{
  description = "patterns";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      git-hooks,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs.lib) optional optionals;

        beamPackages = pkgs.beam.packages.erlang_28;
        elixir = beamPackages.elixir_1_19;

        pre-commit-check = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            treefmt = {
              enable = true;
              package = pkgs.writeShellApplication {
                name = "treefmt";
                runtimeInputs = [
                  pkgs.treefmt
                  pkgs.nixfmt
                  pkgs.shfmt
                ];
                text = ''
                  exec treefmt "$@"
                '';
              };
            };

            deadnix = {
              enable = true;
              settings.edit = false;
            };

            statix = {
              enable = true;
              settings.format = "stderr";
            };

            shellcheck = {
              enable = true;
              package = pkgs.shellcheck;
              excludes = [ ".envrc" ];
            };

            convco = {
              enable = true;
              package = pkgs.convco;
            };

            mix-lint = {
              enable = true;
              name = "mix-lint";
              entry = "${pkgs.writeShellScript "mix-lint" ''
                if [ -n "''${IN_NIX_SHELL:-}" ] || [ -z "''${NIX_BUILD_TOP:-}" ]; then
                  export MIX_HOME="''${MIX_HOME:-$PWD/.nix-mix}"
                  export HEX_HOME="''${HEX_HOME:-$PWD/.nix-hex}"
                  ${elixir}/bin/mix lint
                else
                  exit 0
                fi
              ''}";
              files = "\\.(ex|exs)$";
              pass_filenames = false;
            };

            mix-test = {
              enable = true;
              name = "mix-test";
              entry = "${pkgs.writeShellScript "mix-test" ''
                if [ -n "''${IN_NIX_SHELL:-}" ] || [ -z "''${NIX_BUILD_TOP:-}" ]; then
                  export MIX_HOME="''${MIX_HOME:-$PWD/.nix-mix}"
                  export HEX_HOME="''${HEX_HOME:-$PWD/.nix-hex}"
                  ${elixir}/bin/mix test --color
                else
                  exit 0
                fi
              ''}";
              files = "\\.(ex|exs)$";
              pass_filenames = false;
            };
          };
        };
      in
      {
        checks = {
          pre-commit = pre-commit-check;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            elixir
            beamPackages.erlang
            pkgs.sqlite
            pkgs.git
            pkgs.convco
            pkgs.treefmt
            pkgs.shellcheck
            pkgs.nixfmt
            pkgs.shfmt
          ]
          ++ optional pkgs.stdenv.isLinux pkgs.inotify-tools
          ++ optionals pkgs.stdenv.isDarwin (
            with pkgs.darwin.apple_sdk.frameworks;
            [
              CoreFoundation
              CoreServices
            ]
          );

          shellHook = ''
            export LANG=en_US.UTF-8
            export LC_ALL=en_US.UTF-8
            export ERL_AFLAGS="-kernel shell_history enabled"
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
            mkdir -p $MIX_HOME $HEX_HOME

            ${pre-commit-check.shellHook}
          '';
        };
      }
    );
}
