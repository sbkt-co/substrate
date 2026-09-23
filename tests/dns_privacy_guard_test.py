#!/usr/bin/env python3
"""Exercise the DNS role's public-zone privacy assertion with real Ansible."""

from __future__ import annotations

import json
import subprocess


BASE_VARS = {
    "substrate_domain": "sbkt.co",
    "substrate_tailnet_domain": "net.sbkt.co",
    "substrate_service_domain": "svc.sbkt.co",
    "substrate_secrets_dir": "/nonexistent/substrate-test-secrets",
    "dns_manage_enabled": False,
}


def run_case(name: str, present: list[dict[str, str]], absent: list[dict[str, str]], should_pass: bool) -> None:
    variables = BASE_VARS | {
        "dns_records_present": present,
        "dns_records_absent": absent,
    }
    result = subprocess.run(
        [
            "ansible-playbook",
            "-i",
            "localhost,",
            "tests/dns_privacy_guard.yml",
            "--extra-vars",
            json.dumps(variables),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    passed = result.returncode == 0
    if passed != should_pass:
        expectation = "pass" if should_pass else "reject"
        raise AssertionError(f"{name}: expected role to {expectation}\n{result.stdout}")
    if not should_pass and "A managed record is the private domain" not in result.stdout:
        raise AssertionError(f"{name}: rejected for an unrelated Ansible failure\n{result.stdout}")


def record(name: str) -> dict[str, str]:
    return {"name": name, "type": "A", "value": "203.0.113.10"}


def main() -> None:
    rejected = (
        "net.sbkt.co",
        "node.net.sbkt.co",
        "deep.node.net.sbkt.co",
        "svc.sbkt.co",
        "api.svc.sbkt.co",
        "deep.api.svc.sbkt.co",
        "node.net",
        "api.svc",
        "API.SVC.SBKT.CO",
    )
    for name in rejected:
        run_case(f"present {name}", [record(name)], [], should_pass=False)
        run_case(f"absent cleanup {name}", [], [record(name)], should_pass=True)

    private_targets = (
        {"name": "alias", "type": "CNAME", "value": "node.net.sbkt.co."},
        {"name": "@", "type": "MX", "value": "10 mail.net.sbkt.co"},
        {"name": "_api._tcp", "type": "SRV", "value": "0 5 443 api.svc.sbkt.co."},
    )
    for target in private_targets:
        run_case(f"present private target {target['type']}", [target], [], should_pass=False)
        run_case(f"absent cleanup target {target['type']}", [], [target], should_pass=True)

    allowed = (
        "@",
        "www",
        "api.sbkt.co",
        "net.sbkt.co.example",
        "svc.sbkt.co.example",
        "notnet.sbkt.co",
        "notsvc.sbkt.co",
    )
    run_case("public and near-match names", [record(name) for name in allowed], [], should_pass=True)
    print("DNS public-zone privacy guard passed all exact, descendant, and near-match cases.")


if __name__ == "__main__":
    main()
