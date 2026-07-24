default: check

# Install the pre-commit hooks.
setup:
    uvx pre-commit install

# Lint, format, and secret-scan (same checks as the pre-commit hooks).
check:
    uvx pre-commit run --all-files

# Run the end-to-end harness tests (own uv project; needs podman + network).
test:
    cd tests/openhost && uv run pytest

# Build the container image.
build:
    podman build -t minds .
