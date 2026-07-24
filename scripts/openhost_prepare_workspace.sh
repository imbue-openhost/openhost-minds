#!/usr/bin/env bash
# Assemble the workspace source at DEST from the build-context copy at CTX.
#
# The build context is this app repo with the workspace template checked out
# at openhost_minds_template/ (a git submodule). The workspace the mind lives
# in is the TEMPLATE tree, and its git history must be the template's history:
# the seeded workspace shares ancestry with the deployed template commit, which
# is what lets update-self 3-way merge a newer template into the mind's local
# edits (see the template's scripts/openhost_template_update.py).
#
# In a git clone of this repo the submodule's .git is a pointer file into
# .git/modules/; reconstitute a standalone repo from it. OpenHost's app-update
# path (`oh app reload --update`) pulls the app repo WITHOUT updating the
# submodule worktree, so also verify the worktree matches the gitlink recorded
# in the app repo's HEAD, checking out (and fetching, if needed) the recorded
# commit when they disagree. OpenHost clones submodules shallow; best-effort
# unshallow so future update-self merges have a real merge base.
#
# The test harness deploys a plain snapshot with no git metadata at all; in
# that case skip the history work (the update mechanism is inert without a
# baked version stamp, and the entrypoint git-inits the seeded workspace).
set -euo pipefail

ctx="${1:?usage: openhost_prepare_workspace.sh CTX DEST VERSION_OUT}"
dest="${2:?usage: openhost_prepare_workspace.sh CTX DEST VERSION_OUT}"
version_out="${3:?usage: openhost_prepare_workspace.sh CTX DEST VERSION_OUT}"
tpl="$ctx/openhost_minds_template"

if [ ! -e "$tpl/pyproject.toml" ]; then
    echo "openhost_prepare_workspace: $tpl is missing or empty." >&2
    echo "The openhost_minds_template submodule was not present in the build context;" >&2
    echo "run 'git submodule update --init' in the checkout OpenHost builds from." >&2
    exit 1
fi

# Turn the submodule checkout into a standalone repo: replace the .git pointer
# file with the module's real git dir and drop its worktree redirection.
if [ -f "$tpl/.git" ] && [ -d "$ctx/.git/modules/openhost_minds_template" ]; then
    rm "$tpl/.git"
    mv "$ctx/.git/modules/openhost_minds_template" "$tpl/.git"
    # Edit the config file directly: the stale relative core.worktree makes
    # every `git -C` invocation fail outright until it is gone.
    git config --file "$tpl/.git/config" --unset core.worktree || true
fi

if [ -d "$tpl/.git" ]; then
    # If the app repo records a different template commit than the worktree
    # (OpenHost's pull path leaves submodules stale), move to the recorded one.
    gitlink=""
    if [ -d "$ctx/.git" ]; then
        gitlink="$(git -C "$ctx" ls-tree HEAD openhost_minds_template 2>/dev/null | awk '{print $3}')" || gitlink=""
    fi
    head_sha="$(git -C "$tpl" rev-parse HEAD)"
    if [ -n "$gitlink" ] && [ "$gitlink" != "$head_sha" ]; then
        echo "openhost_prepare_workspace: template worktree at $head_sha but app repo records $gitlink; checking out recorded commit" >&2
        if ! git -C "$tpl" checkout -qf "$gitlink" 2>/dev/null; then
            if ! { git -C "$tpl" fetch origin "$gitlink" && git -C "$tpl" checkout -qf "$gitlink"; }; then
                echo "openhost_prepare_workspace: could not check out $gitlink; the submodule" >&2
                echo "commit is not available locally or from origin. Push the template commit" >&2
                echo "and redeploy, or update the submodule worktree in the build checkout." >&2
                exit 1
            fi
        fi
    fi
    # OpenHost clones submodules with --shallow-submodules; without full history
    # the workspace and a future incoming template commit have no merge base.
    if [ -f "$tpl/.git/shallow" ]; then
        git -C "$tpl" fetch --unshallow origin \
            || echo "openhost_prepare_workspace: WARNING: could not unshallow template history; update-self merges may lack a merge base" >&2
    fi
    git -C "$tpl" rev-parse HEAD > "$version_out"
else
    echo "openhost_prepare_workspace: no template git history in build context; skipping version stamp (update-self staging will be inert)" >&2
fi

mkdir -p "$dest"
cp -a "$tpl/." "$dest/"
