import shutil
import subprocess
import tomllib
from pathlib import Path

import pytest
from openhost_test_harness import OpenhostStack

# First boot builds the image (slow when the podman layer cache is cold),
# seeds the workspace onto the volume, and creates the system-services agent
# before system_interface starts answering the health probe.
DEPLOY_TIMEOUT = 1800.0


LATCHKEY_REPO_URL = "https://github.com/imbue-openhost/openhost-latchkey"

REPO_ROOT = Path(__file__).parent.parent.parent
TEMPLATE_SUBDIR = "openhost_minds_template"


def _snapshot_working_tree(repo_dir: Path, dest: Path) -> None:
    """Copy ``repo_dir``'s git working tree to ``dest``: tracked + untracked
    files, minus gitignored ones and ``.git`` itself (submodule gitlinks are
    skipped too -- they are not files)."""
    listing = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=repo_dir,
        capture_output=True,
        check=True,
    )
    for raw in listing.stdout.split(b"\0"):
        if not raw:
            continue
        src = repo_dir / raw.decode()
        if not src.is_file():  # staged deletions still appear in ls-files
            continue
        target = dest / raw.decode()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)


@pytest.fixture(scope="session")
def app_src(tmp_path_factory) -> Path:
    """Deployable snapshot of this repo with the template submodule's working
    tree materialized under openhost_minds_template/.

    The harness's own snapshot logic uses ``git ls-files`` on the app repo,
    which skips submodule content entirely; assembling both working trees here
    keeps the deploy reflecting uncommitted changes in BOTH repos. The result
    has no .git, so the router copies it verbatim (no clone) and the image's
    template-history machinery is inert -- fine for these tests.
    """
    dest = tmp_path_factory.mktemp("app-under-test")
    _snapshot_working_tree(REPO_ROOT, dest)
    _snapshot_working_tree(REPO_ROOT / TEMPLATE_SUBDIR, dest / TEMPLATE_SUBDIR)
    return dest


@pytest.fixture(scope="session")
def stack(app_src):
    def _deploy_latchkey(s: OpenhostStack) -> None:
        s.deploy_app(LATCHKEY_REPO_URL)

    with OpenhostStack(app_dir=app_src, deploy_timeout=DEPLOY_TIMEOUT, pre_deploy=_deploy_latchkey) as s:
        yield s


@pytest.fixture(scope="session")
def app_name() -> str:
    manifest = REPO_ROOT / "openhost.toml"
    return tomllib.loads(manifest.read_text())["app"]["name"]


@pytest.fixture(scope="session")
def container_name(app_name) -> str:
    return f"openhost-{app_name}"


@pytest.fixture(scope="session")
def app_data_dir(stack, app_name) -> Path:
    return Path(stack.local_stack.config.persistent_data_dir) / "app_data" / app_name
