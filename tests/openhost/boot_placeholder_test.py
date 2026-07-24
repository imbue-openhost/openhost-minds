"""The boot placeholder's handover contract, without deploying anything.

The port is unserved for seconds between the placeholder exiting and
system_interface binding it, so the page must not navigate on a timer -- it
polls and reloads only when a response arrives without the marker header.
"""

import importlib.util
import socket
import threading
from pathlib import Path

import pytest
import requests

REPO_ROOT = Path(__file__).parent.parent.parent
PLACEHOLDER_SCRIPT = REPO_ROOT / "scripts" / "openhost_boot_placeholder.py"


def _load_placeholder():
    spec = importlib.util.spec_from_file_location("openhost_boot_placeholder", PLACEHOLDER_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def placeholder_address():
    module = _load_placeholder()
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = module.ThreadingHTTPServer(("127.0.0.1", port), module.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield ("127.0.0.1", port)
    finally:
        server.shutdown()
        server.server_close()


@pytest.fixture
def placeholder_url(placeholder_address):
    host, port = placeholder_address
    return f"http://{host}:{port}/"


def test_marker_header_identifies_the_placeholder(placeholder_url):
    resp = requests.get(placeholder_url, timeout=10)
    assert resp.status_code == 200
    assert resp.headers["X-Openhost-Boot-Placeholder"] == "1"
    assert resp.headers["Cache-Control"] == "no-store"


def test_head_sends_headers_without_a_body(placeholder_address):
    """Read the raw bytes: HTTP clients discard anything after the headers of a
    HEAD response, so a body written here is only visible off the wire."""
    with socket.create_connection(placeholder_address, timeout=10) as sock:
        sock.sendall(b"HEAD / HTTP/1.0\r\n\r\n")
        chunks = []
        while chunk := sock.recv(4096):
            chunks.append(chunk)
    head, separator, body = b"".join(chunks).partition(b"\r\n\r\n")
    assert separator, head
    assert b"X-Openhost-Boot-Placeholder: 1" in head
    assert body == b""


def test_page_polls_instead_of_refreshing(placeholder_url):
    body = requests.get(placeholder_url, timeout=10).text
    assert "http-equiv" not in body, "a meta refresh navigates into the handover gap and hits the router's 502"
    assert "x-openhost-boot-placeholder" in body, "the page must check the marker before reloading"
