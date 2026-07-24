# openhost-minds (OpenHost app wrapper)

This repo is ONLY the OpenHost wrapper for the minds workspace: app manifest
(`openhost.toml`), image build (`Dockerfile` + `scripts/`), and end-to-end
harness tests (`tests/openhost/`).

The workspace template itself lives in the `openhost_minds_template/` git
submodule (its own repo: imbue-openhost/openhost-minds-template). Rules:

- Do NOT run the template's test suites, ratchets, or CI gates from this repo.
  Template development, and its tests, happen in the template repo.
- This repo's tests: `cd tests/openhost && uv run pytest` (own uv project;
  requires podman + network; slow — builds the image and boots a real router).
- Template changes land in the template repo; this repo consumes them by
  bumping the submodule pointer.
- The Dockerfile mirrors the template's Dockerfile layer structure (paths
  prefixed with `openhost_minds_template/`). If the template's Dockerfile
  changes, mirror the change here.
