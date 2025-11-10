{
  description = "MaxReview - Automated multi-agent code review tool for GitHub PRs";

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
            echo "🚀 MaxReview development environment loaded!"
            echo ""
            echo "Python: $(python --version)"
            echo "Available commands:"
            echo "  just lint      - Run linters (black, ruff, mypy)"
            echo "  just test      - Run tests with pytest"
            echo "  just run       - Run maxreview CLI"
            echo "  just install   - Install package in editable mode"
            echo "  just check-sh  - Check bash scripts with shellcheck"
            echo ""

            # Install package in editable mode if not already installed
            if ! python -c "import maxreview" 2>/dev/null; then
              echo "Installing maxreview in editable mode..."
              pip install -e . --quiet
            fi
          '';

          # Environment variables
          PYTHONPATH = "${pythonEnv}/${pythonEnv.sitePackages}";
        };

        # Package definition for maxreview
        packages.default = pkgs.python312Packages.buildPythonApplication {
          pname = "maxreview";
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
            homepage = "https://github.com/forketyfork/maxreview";
            license = licenses.mit;
            maintainers = [ ];
          };
        };

        # Make the app directly runnable
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/maxreview";
        };
      }
    );
}
