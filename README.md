# openhost-minds

The installable [OpenHost](https://github.com/imbue-openhost/openhost) app ("minds"): a
persistent autonomous AI agent workspace. The container is a single workspace host serving the
system_interface web UI, with Claude Code agents in tmux managed by in-container mngr (local
provider). The OpenHost router terminates TLS and auth; there is no desktop app, VM layer, or
Cloudflare tunnel, and exactly one mind per app install.

The workspace itself is the
[openhost-minds-template](https://github.com/imbue-openhost/openhost-minds-template), checked out
as the `openhost_minds_template/` git submodule. This repo holds only the OpenHost wrapper: the
app manifest, the image build, the container entrypoint, and the end-to-end harness tests. Clone
with `git clone --recurse-submodules`, or run `git submodule update --init` after a plain clone.

- `openhost.toml` — the app manifest. Routes the app port to system_interface and consumes two
  cross-app services: the [bifrost LLM gateway](https://github.com/imbue-openhost/openhost-bifrost-llm-gateway)
  (`ANTHROPIC_BASE_URL` points at its `/anthropic` drop-in through the router service proxy) and
  [openhost-latchkey](https://github.com/imbue-openhost/openhost-latchkey) (third-party API calls
  with the owner's credentials injected; see the template's `latchkey` skill).
- `Dockerfile` — mirrors the template's own Dockerfile layer structure with paths prefixed for
  the submodule layout; keep the two in sync when the template's Dockerfile changes.
- `scripts/openhost_prepare_workspace.sh` — build-time assembly of the workspace source from the
  submodule, reconstituting the template's git history so update-self can merge newer deployed
  template versions into a live mind's local edits.
- `scripts/openhost_entrypoint.sh` — replaces the desktop client + outer mngr provisioning:
  symlinks `/mngr` onto `OPENHOST_APP_DATA_DIR`, stages pending template updates, seeds the
  workspace on first boot, writes the host env (service URLs, app token, `IS_SANDBOX=1` and the
  other per-host vars the create templates only apply to new hosts), creates the
  `system-services` agent, restarts it on warm boots, and tails supervisor logs as PID 1.
- `tests/openhost/` — end-to-end harness tests (own uv project): they deploy this app through a
  real local OpenHost router under podman, with the real openhost-latchkey app as provider.
  Run with `cd tests/openhost && uv run pytest`. Requires podman and network.

## Updating the template

Bump the submodule and redeploy:

```bash
cd openhost_minds_template && git fetch && git checkout origin/main && cd ..
git add openhost_minds_template && git commit -m "Bump template" && git push
oh app reload minds --update --wait
```

On the next boot the entrypoint stages the new template commit into the live workspace as
`refs/openhost/incoming` and the mind is prompted to reconcile via its `update-self` skill.

Note: OpenHost's `--update` pull currently does not run `git submodule update`, so the build
checkout's submodule worktree can be stale; `scripts/openhost_prepare_workspace.sh` detects the
mismatch against the recorded gitlink and checks out (fetching if needed) the recorded commit.
