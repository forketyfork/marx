{
  description = "Marx - Automated multi-agent code review tool for GitHub PRs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        pythonEnv = pkgs.python312.withPackages (ps: with ps; [
          # Core dependencies
          click
          rich
          docker
          pydantic

          # Development dependencies
          pytest
          pytest-cov
          pytest-asyncio
          black
          ruff
          mypy

          # Additional useful tools
          ipython
          pip
        ]);

      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Python environment
            pythonEnv

            # System dependencies
            git
            gh
            jq
            docker

            # Development tools
            just
            shellcheck

            # Optional: Useful utilities
            fd
            ripgrep
            tree
          ];

          shellHook = ''
            echo "🚀 Marx development environment loaded!"
            echo ""
            echo "Python: $(python --version)"
            echo "Available commands:"
            echo "  marx           - Run marx CLI (uses local source)"
            echo "  just lint      - Run linters (black, ruff, mypy)"
            echo "  just test      - Run tests with pytest"
            echo "  just run       - Run marx CLI"
            echo "  just check-sh  - Check bash scripts with shellcheck"
            echo ""
            echo "Note: In this Nix environment, the marx command runs from your local source."
            echo "      All changes to the code are immediately available."
            echo ""

            # Add current directory to PYTHONPATH for development
            export PYTHONPATH="$PWD:$PYTHONPATH"

            # Create marx wrapper script in a temporary bin directory
            mkdir -p .nix-bin
            cat > .nix-bin/marx <<'EOF'
#!/usr/bin/env bash
exec python -m marx.cli "$@"
EOF
            chmod +x .nix-bin/marx
            export PATH="$PWD/.nix-bin:$PATH"
          '';

          # Environment variables
          PYTHONPATH = "${pythonEnv}/${pythonEnv.sitePackages}";
        };

        # Package definition for marx
        packages.default = pkgs.python312Packages.buildPythonApplication {
          pname = "marx";
          version = "1.0.0";

          src = ./.;

          format = "pyproject";

          nativeBuildInputs = with pkgs.python312Packages; [
            setuptools
            wheel
          ];

          propagatedBuildInputs = with pkgs.python312Packages; [
            click
            rich
            docker
            pydantic
          ];

          checkInputs = with pkgs.python312Packages; [
            pytest
            pytest-cov
          ];

          meta = with pkgs.lib; {
            description = "Automated multi-agent code review tool for GitHub PRs";
            homepage = "https://github.com/forketyfork/marx";
            license = licenses.mit;
            maintainers = [ ];
          };
        };

        # Make the app directly runnable
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/marx";
        };
      }
    );
}
