# OpenHost app image for "minds". The workspace source is the template checked
# out at openhost_minds_template/ (git submodule); this file mirrors the
# template's own Dockerfile layer structure (system toolchain -> manifest-only
# dependency layer -> full source -> bake/relocate) with paths prefixed for the
# submodule layout, plus the OpenHost entrypoint. When the template's
# Dockerfile changes, mirror the change here -- noting that the source stage is
# split into a throwaway assembly stage for cache reasons (see below), and that
# the template's separate build and relocate steps are one layer here.
FROM python:3.12.13-slim-bookworm AS base

# /root/.local/bin holds uv + claude (installed by the template's
# scripts/setup_system.sh); put it on PATH for every build layer and at runtime.
ENV PATH="/root/.local/bin:$PATH"

# Pin Claude Code; passed to setup_system.sh and recorded for the runtime version
# check. Keep in sync with agent_types.claude.version in the template's
# .mngr/settings.toml and the default in its scripts/setup_system.sh.
ARG CLAUDE_CODE_VERSION=2.1.207
ENV CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}

# ============================================================================
# System toolchain (repo-independent). setup_system.sh installs the system
# toolchain AND invokes install_secret_scanners.sh (both from the template).
# Copied with its sibling _provision_guard.sh (sourced via `dirname "$0"`) and
# nothing else, so this expensive, stable layer caches against these scripts +
# pinned versions, not application source.
# ============================================================================
COPY openhost_minds_template/scripts/setup_system.sh /usr/local/bin/default-workspace-template-setup-system
COPY openhost_minds_template/scripts/_provision_guard.sh /usr/local/bin/_provision_guard.sh
COPY openhost_minds_template/scripts/install_secret_scanners.sh /usr/local/bin/default-workspace-template-install-secret-scanners
RUN chmod +x /usr/local/bin/default-workspace-template-setup-system /usr/local/bin/default-workspace-template-install-secret-scanners && default-workspace-template-setup-system

# Safety-net symlinks: /code -> /mngr/code and /worktree -> /mngr/worktree
# (see the template Dockerfile for the rationale).
RUN ln -s /mngr/code /code && ln -s /mngr/worktree /worktree

# ============================================================================
# Workspace assembly stage. Discarded -- only its two outputs are copied into
# the image below.
#
# This is where the build context (the whole app repo, including .git and
# .git/modules -- see .dockerignore) is consumed, so the app repo's git state
# stays out of the main chain's cache key. That matters because .git changes on
# every commit and every `oh app reload --update` pull, which would otherwise
# invalidate the workspace build below even when the template is untouched.
# podman keys a `COPY --from` on the copied CONTENT, so the main chain only
# rebuilds when the assembled workspace actually differs.
# ============================================================================
FROM base AS workspace-src

COPY scripts/openhost_prepare_workspace.sh /usr/local/bin/openhost-minds-prepare-workspace
COPY . /openhost_build_ctx/

# Assemble the workspace from the template subtree, with the template's real
# git history reconstituted from the submodule and the deployed template SHA
# written out. That history is what lets update-self merge a newer deployed
# template into an existing workspace (see the prepare script).
RUN chmod +x /usr/local/bin/openhost-minds-prepare-workspace \
    && openhost-minds-prepare-workspace \
        /openhost_build_ctx /openhost_workspace_src /openhost_template_version

# ============================================================================
# Main image.
# ============================================================================
FROM base

# ============================================================================
# Pre-COPY manifest layer.
# Copies only the dependency manifests (no application source) so the
# expensive dependency install below caches against dependency-manifest
# changes only.
# ============================================================================
WORKDIR /mngr/code/

# Root + per-workspace-member pyproject.toml + uv.lock.
COPY openhost_minds_template/pyproject.toml openhost_minds_template/uv.lock /mngr/code/
COPY openhost_minds_template/libs/app_watcher/pyproject.toml /mngr/code/libs/app_watcher/pyproject.toml
COPY openhost_minds_template/libs/bootstrap/pyproject.toml /mngr/code/libs/bootstrap/pyproject.toml
COPY openhost_minds_template/libs/cloudflare_tunnel/pyproject.toml /mngr/code/libs/cloudflare_tunnel/pyproject.toml
COPY openhost_minds_template/libs/github_sync/pyproject.toml /mngr/code/libs/github_sync/pyproject.toml
COPY openhost_minds_template/apps/system_interface/pyproject.toml /mngr/code/apps/system_interface/pyproject.toml

# vendor/mngr path-dependency manifests (see the template Dockerfile).
COPY openhost_minds_template/vendor/mngr/libs/imbue_common/pyproject.toml /mngr/code/vendor/mngr/libs/imbue_common/pyproject.toml
COPY openhost_minds_template/vendor/mngr/libs/mngr/pyproject.toml /mngr/code/vendor/mngr/libs/mngr/pyproject.toml
COPY openhost_minds_template/vendor/mngr/libs/mngr_claude/pyproject.toml /mngr/code/vendor/mngr/libs/mngr_claude/pyproject.toml
COPY openhost_minds_template/vendor/mngr/libs/mngr_modal/pyproject.toml /mngr/code/vendor/mngr/libs/mngr_modal/pyproject.toml
COPY openhost_minds_template/vendor/mngr/libs/mngr_wait/pyproject.toml /mngr/code/vendor/mngr/libs/mngr_wait/pyproject.toml
COPY openhost_minds_template/vendor/mngr/libs/resource_guards/pyproject.toml /mngr/code/vendor/mngr/libs/resource_guards/pyproject.toml
COPY openhost_minds_template/vendor/mngr/libs/concurrency_group/pyproject.toml /mngr/code/vendor/mngr/libs/concurrency_group/pyproject.toml

# Frontend npm manifest (lockfile + package.json) -- install needs only these.
COPY openhost_minds_template/apps/system_interface/frontend/package.json openhost_minds_template/apps/system_interface/frontend/package-lock.json /mngr/code/apps/system_interface/frontend/

# Dependency install (manifests only).
COPY openhost_minds_template/scripts/install_dependencies.sh /usr/local/bin/default-workspace-template-install-dependencies
RUN chmod +x /usr/local/bin/default-workspace-template-install-dependencies && default-workspace-template-install-dependencies

# ============================================================================
# End pre-COPY manifest layer. Source-changing layers begin below.
# ============================================================================

# The workspace source assembled by the stage above.
COPY --from=workspace-src /openhost_workspace_src /mngr/code/

# Build the workspace from full source, then move it off the volume mount path
# so the shipped image has /mngr/code/ EMPTY: at runtime /mngr/ is a persistent
# volume mount, and the first-boot seed relocates /docker_build_code onto it.
# The move crosses overlay layers, so it rewrites the whole ~1GB tree; keeping
# it in the build's own layer writes that tree once instead of twice.
RUN bash /mngr/code/scripts/build_workspace.sh && mv /mngr/code /docker_build_code

# WORKDIR must leave /mngr/code or later layers silently recreate it as an
# empty dir, which blocks the entrypoint's /mngr symlink onto the app-data dir.
WORKDIR /

# Deployed template SHA at a stable image-layer path (empty file when the build
# context carried no template history -- readers treat that as unstamped).
COPY --from=workspace-src /openhost_template_version /opt/openhost-template-version

# First-boot seed script at a stable image-layer path (outside /mngr/ and
# /docker_build_code; see the template Dockerfile for the full rationale).
COPY openhost_minds_template/scripts/default_workspace_template_seed.sh /usr/local/bin/default-workspace-template-seed
RUN chmod +x /usr/local/bin/default-workspace-template-seed

# OpenHost entrypoint: replaces the desktop client + outer mngr provisioning
# (state onto OPENHOST_APP_DATA_DIR, first-boot seed + agent create, warm-boot
# restart, supervisor logs to stdout).
COPY scripts/openhost_entrypoint.sh /usr/local/bin/openhost-minds-entrypoint
# The boot placeholder must be runnable before the first-boot seed puts the
# workspace at /mngr/code, so it ships at an image-layer path too.
COPY scripts/openhost_boot_placeholder.py /usr/local/bin/openhost-boot-placeholder
RUN chmod +x /usr/local/bin/openhost-minds-entrypoint /usr/local/bin/openhost-boot-placeholder
ENTRYPOINT ["tini", "--", "/usr/local/bin/openhost-minds-entrypoint"]
