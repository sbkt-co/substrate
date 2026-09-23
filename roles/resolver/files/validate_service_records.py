#!/usr/bin/env python3
"""Validate records before they cross into a CoreDNS zone file."""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys

OWNER_RE = re.compile(
    r"^(@|[A-Za-z0-9_*](?:[A-Za-z0-9_*-]{0,61}[A-Za-z0-9_*])?"
    r"(?:\.[A-Za-z0-9_*](?:[A-Za-z0-9_*-]{0,61}[A-Za-z0-9_*])?)*)$"
)
FQDN = r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
FQDN_RE = re.compile(rf"^{FQDN}$")
MX_RE = re.compile(rf"^\d{{1,5}} {FQDN}$")
SRV_RE = re.compile(rf"^\d{{1,5}} \d{{1,5}} \d{{1,5}} {FQDN}$")
ALLOWED_TYPES = {"A", "AAAA", "CNAME", "TXT", "MX", "SRV"}


def validate_records(records: object, default_ttl: int) -> None:
    if not isinstance(records, list):
        raise ValueError("resolver_service_records must be a list")
    for record in records:
        if not isinstance(record, dict):
            raise ValueError(f"record is not a mapping: {record!r}")
        missing = {"name", "type", "value"} - record.keys()
        if missing:
            raise ValueError(f"record is missing {sorted(missing)}: {record!r}")

        name = record["name"]
        record_type = record["type"]
        value = record["value"]
        if not isinstance(name, str) or not OWNER_RE.fullmatch(name) or name.lower() == "ns":
            raise ValueError(f"invalid or reserved record name: {name!r}")
        if not isinstance(record_type, str) or record_type.upper() not in ALLOWED_TYPES:
            raise ValueError(f"unsupported record type: {record_type!r}")
        if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
            raise ValueError(f"invalid record value: {value!r}")
        try:
            ttl = int(record.get("ttl", default_ttl))
        except (TypeError, ValueError) as error:
            raise ValueError(f"invalid TTL: {record.get('ttl')!r}") from error
        if ttl <= 0:
            raise ValueError(f"TTL must be positive: {ttl}")

        normalized_type = record_type.upper()
        try:
            if normalized_type == "A" and ipaddress.ip_address(value).version != 4:
                raise ValueError("A record requires IPv4")
            if normalized_type == "AAAA" and ipaddress.ip_address(value).version != 6:
                raise ValueError("AAAA record requires IPv6")
        except ValueError as error:
            if normalized_type in {"A", "AAAA"}:
                raise ValueError(f"invalid {normalized_type} value: {value!r}") from error
        if normalized_type == "CNAME" and not FQDN_RE.fullmatch(value):
            raise ValueError(f"CNAME target must be an absolute FQDN: {value!r}")
        if normalized_type == "MX" and not MX_RE.fullmatch(value):
            raise ValueError(f"MX value must be '<priority> <absolute-fqdn>': {value!r}")
        if normalized_type == "SRV" and not SRV_RE.fullmatch(value):
            raise ValueError(f"SRV value must be '<priority> <weight> <port> <absolute-fqdn>': {value!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--default-ttl", required=True, type=int)
    args = parser.parse_args()
    try:
        validate_records(json.load(sys.stdin), args.default_ttl)
    except (TypeError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
