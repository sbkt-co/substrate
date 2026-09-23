#!/usr/bin/env python3
"""Validate cached or freshly discovered Headscale resolver addresses."""

from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import json
import sys


def validate_address(value: str, prefix: str) -> str:
    address = ipaddress.ip_address(value.strip())
    network = ipaddress.ip_network(prefix)
    if address.version != 4 or network.version != 4 or address not in network:
        raise ValueError(f"{address} is outside {network}")
    return str(address)


def select_node_address(raw_nodes: str, wanted: str, prefix: str) -> str:
    nodes = json.loads(raw_nodes)
    if not isinstance(nodes, list):
        raise ValueError("node list is not a JSON list")
    matches = [
        node
        for node in nodes
        if isinstance(node, dict)
        and (node.get("given_name") == wanted or node.get("name") == wanted)
    ]
    if len(matches) != 1:
        raise ValueError(f"expected one node named {wanted!r}, found {len(matches)}")

    values = matches[0].get("ip_addresses", [])
    if not isinstance(values, list):
        raise ValueError("node ip_addresses is not a list")
    addresses = []
    for value in values:
        try:
            address = ipaddress.ip_address(value)
        except (TypeError, ValueError):
            continue
        if address.version == 4:
            addresses.append(str(address))
    if len(addresses) != 1:
        raise ValueError(f"expected one IPv4 address, found {len(addresses)}")
    return validate_address(addresses[0], prefix)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--node-name")
    parser.add_argument("--base64-input", action="store_true")
    args = parser.parse_args()
    raw = sys.stdin.read()
    try:
        if args.base64_input:
            raw = base64.b64decode(raw.strip(), validate=True).decode()
        selected = (
            select_node_address(raw, args.node_name, args.prefix)
            if args.node_name
            else validate_address(raw, args.prefix)
        )
    except (binascii.Error, UnicodeDecodeError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
