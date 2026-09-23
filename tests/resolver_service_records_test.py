#!/usr/bin/env python3
"""Behavior checks for git-managed service-record validation."""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "roles/resolver/files/validate_service_records.py"


def load_validator():
    spec = importlib.util.spec_from_file_location("validate_service_records", VALIDATOR)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {VALIDATOR}")
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
    validator = load_validator()
    valid = [
        {"name": "api", "type": "A", "value": "100.64.0.2"},
        {"name": "alias", "type": "CNAME", "value": "node.net.sbkt.co."},
        {"name": "@", "type": "MX", "value": "10 mail.net.sbkt.co."},
        {"name": "_api._tcp", "type": "SRV", "value": "0 5 443 node.net.sbkt.co."},
        {"name": "label", "type": "TXT", "value": '"service metadata"'},
    ]
    validator.validate_records(valid, default_ttl=300)

    expect_error(
        lambda: validator.validate_records(
            [{"name": "alias", "type": "CNAME", "value": "node.net.sbkt.co"}], 300
        ),
        "a relative CNAME target was accepted",
    )
    expect_error(
        lambda: validator.validate_records(
            [{"name": "bad", "type": "TXT", "value": '"ok"\ninjected A 203.0.113.1'}], 300
        ),
        "a multiline zone injection was accepted",
    )
    expect_error(
        lambda: validator.validate_records(
            [{"name": "ns", "type": "CNAME", "value": "node.net.sbkt.co."}], 300
        ),
        "a record colliding with the generated nameserver was accepted",
    )

    print("Resolver service-record validation passed type-specific safety cases.")


if __name__ == "__main__":
    main()
