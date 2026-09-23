#!/usr/bin/env python3
"""Behavior checks for Headscale resolver-address selection."""

from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SELECTOR = ROOT / "roles/headscale/files/select_resolver_address.py"


def load_selector():
    spec = importlib.util.spec_from_file_location("select_resolver_address", SELECTOR)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SELECTOR}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect_error(call, message: str) -> None:
    try:
        call()
    except ValueError:
        return
    raise AssertionError(message)


def main() -> None:
    selector = load_selector()

    assert selector.validate_address("10.23.4.5", "10.0.0.0/8") == "10.23.4.5"
    expect_error(
        lambda: selector.validate_address("100.64.0.1", "10.0.0.0/8"),
        "an address outside the configured prefix was accepted",
    )

    nodes = [
        {
            "given_name": "display-name",
            "name": "resolver-node",
            "ip_addresses": ["10.23.4.5", "fd7a:115c:a1e0::1"],
        }
    ]
    raw_nodes = json.dumps(nodes)
    assert selector.select_node_address(raw_nodes, "resolver-node", "10.0.0.0/8") == "10.23.4.5"

    encoded_nodes = base64.b64encode(raw_nodes.encode()).decode()
    result = subprocess.run(
        [
            sys.executable,
            str(SELECTOR),
            "--prefix",
            "10.0.0.0/8",
            "--node-name",
            "resolver-node",
            "--base64-input",
        ],
        input=f"{encoded_nodes}\n",
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "10.23.4.5"

    expect_error(
        lambda: selector.select_node_address(json.dumps(nodes * 2), "resolver-node", "10.0.0.0/8"),
        "duplicate matching nodes were accepted",
    )
    expect_error(
        lambda: selector.select_node_address(json.dumps(nodes), "other-node", "10.0.0.0/8"),
        "a missing node identity was accepted",
    )
    malformed_address_nodes = [
        {"given_name": "resolver-node", "ip_addresses": ["not-an-address"]}
    ]
    expect_error(
        lambda: selector.select_node_address(
            json.dumps(malformed_address_nodes), "resolver-node", "10.0.0.0/8"
        ),
        "a node without one valid IPv4 address was accepted",
    )
    expect_error(
        lambda: selector.select_node_address("not-json", "resolver-node", "10.0.0.0/8"),
        "malformed node JSON was accepted",
    )

    print("Headscale resolver-address selection passed custom-prefix and identity cases.")


if __name__ == "__main__":
    main()
