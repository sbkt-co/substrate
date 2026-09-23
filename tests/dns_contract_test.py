#!/usr/bin/env python3
"""Focused static contract checks for the split-DNS architecture."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text()


def main() -> None:
    failures: list[str] = []

    group_vars = text("group_vars/all.yml")
    if "substrate_service_domain: svc.sbkt.co" not in group_vars:
        failures.append("group_vars must define svc.sbkt.co as substrate_service_domain")
    if "substrate_resolver_wire_dns" in group_vars or "substrate_resolver_address:" in group_vars:
        failures.append("manual resolver gate/address variables must be removed")

    headscale_defaults = text("roles/headscale/defaults/main.yml")
    if "headscale_system_user: headscale" not in headscale_defaults or "headscale_system_group: headscale" not in headscale_defaults:
        failures.append("Headscale state-directory ownership must follow the packaged systemd service account")

    headscale_tasks = text("roles/headscale/tasks/main.yml")
    for required in (
        "headscale_nodes_list_argv",
        "headscale_resolver_address_cache",
        "headscale_effective_resolver_address",
        "headscale_resolver_selector",
        '"{{ headscale_prefix_v4 }}"',
        "headscale_resolver_enabled",
        "Bootstrap headscale configuration before discovery",
        "Withdraw stale resolver state when the resolver role is absent",
    ):
        if required not in headscale_tasks:
            failures.append(f"headscale discovery/LKG flow is missing {required!r}")

    headscale = text("roles/headscale/templates/config.yaml.j2")
    if "split:" not in headscale or "substrate_service_domain" not in headscale:
        failures.append("headscale template must render split DNS for the service domain")
    if "override_local_dns" in headscale:
        failures.append("headscale must not override ordinary client DNS")

    resolver_tasks = text("roles/resolver/tasks/main.yml")
    resolver_defaults = text("roles/resolver/defaults/main.yml")
    service_zone = text("roles/resolver/templates/internal.zone.j2")
    if "headscale nodes list" in resolver_tasks:
        failures.append("resolver role must not generate service records from Headscale nodes")
    if "resolver_service_records" not in resolver_defaults:
        failures.append("resolver defaults must expose git-managed service records")
    if "$ORIGIN {{ substrate_service_domain }}." not in service_zone or " SOA " not in service_zone:
        failures.append("service zone must be a standard authoritative zone")
    if any(line.lstrip().startswith("#") for line in service_zone.splitlines()):
        failures.append("service zone comments must use DNS-standard semicolons, not shell-style hashes")

    corefile = text("roles/resolver/templates/Corefile.j2")
    if "substrate_service_domain" not in corefile:
        failures.append("CoreDNS must be authoritative for the service domain")
    if "fallthrough" in corefile:
        failures.append("service-zone misses must not fall through to public DNS")
    if "{{ substrate_tailnet_domain }}" not in corefile or "forward . 100.100.100.100" not in corefile:
        failures.append("CoreDNS must resolve MagicDNS targets without forwarding private names publicly")

    cert_defaults = text("roles/cert_issuer/defaults/main.yml")
    cert_tasks = text("roles/cert_issuer/tasks/main.yml")
    if 'cert_issuer_name: "{{ substrate_domain }}"' not in cert_defaults:
        failures.append("certificate lineage must use the public domain")
    if '"*.{{ substrate_domain }}"' not in cert_tasks or '"*.{{ substrate_tailnet_domain }}"' in cert_tasks:
        failures.append("certificate SANs must use only the public wildcard")
    if "Retire the obsolete internal certificate lineage" not in cert_tasks or "cert_issuer_live_stat.stat.exists" not in cert_tasks:
        failures.append("old internal certificate lineage must retire only after public issuance")
    retirement = cert_tasks.split("Retire the obsolete internal certificate lineage", 1)[1].split("# Steady-state", 1)[0]
    if "changed_when: true" in retirement:
        failures.append("certificate-lineage retirement must preserve command removes idempotence")

    incus_run = text("tests/incus/run.sh")
    for phase in (
        "assert first converge has no resolver route",
        "assert enrollment starts CoreDNS before resolver discovery",
        "converge once more so headscale wires split DNS",
        "assert idempotence does not restart headscale",
        "reject failed resolver discovery without replacing LKG",
        "reject malformed resolver discovery without replacing LKG",
        "accept a changed valid resolver address",
    ):
        if phase not in incus_run:
            failures.append(f"Incus lifecycle is missing phase {phase!r}")

    incus_verify = text("tests/incus/verify.yml")
    for required in (
        "/var/lib/substrate/resolver-address",
        "svc.sbkt.co",
        "file /etc/coredns/internal.zone svc.sbkt.co",
        "Assert Headscale split DNS routes only the service domain",
    ):
        if required not in incus_verify:
            failures.append(f"Incus DNS verification is missing {required!r}")
    if "'fallthrough' in" in incus_verify or "'hosts /etc/coredns/internal.zone' in" in incus_verify:
        failures.append("Incus DNS verification still accepts the obsolete hosts/fallthrough configuration")

    staging_core = text("host_vars/staging-core.yml")
    roles = staging_core.split("node_roles:", 1)[1].split("\n\n", 1)[0]
    tailnet_position = roles.find("- tailnet")
    resolver_position = roles.find("- resolver")
    if tailnet_position < 0 or resolver_position < 0 or resolver_position < tailnet_position:
        failures.append("staging-core must run resolver after tailnet")
    if "control" not in staging_core or "staging-core.{{ substrate_tailnet_domain }}." not in staging_core:
        failures.append("staging-core must define a deterministic git-managed service record")

    staging_up = text("staging/up.sh")
    if "wire the resolver split route" not in staging_up:
        failures.append("staging bring-up must include a dedicated post-enrollment DNS-wiring converge")
    if "OnBootSec=1d" in staging_up:
        failures.append("staging pause must not use a boot-relative deadline on persistent nodes")
    for reconciler_guard in (
        "pause_reconcilers",
        "resume_reconcilers",
        "systemctl stop substrate-reconcile.timer substrate-reconcile.service",
        "staging-harness.conf",
        "OnUnitInactiveSec=1d",
        "verify split DNS before resuming branch reconciliation",
        "tailscale debug netmap",
    ):
        if reconciler_guard not in staging_up:
            failures.append(
                "staging working-tree convergence must prevent branch reconciliation races: "
                f"missing {reconciler_guard!r}"
            )

    taskfile = text("Taskfile.yml")
    for status_probe in ("systemctl is-active coredns", "svc.sbkt.co", "resolver-address"):
        if status_probe not in taskfile:
            failures.append(f"staging status is missing {status_probe!r}")

    dns_defaults = text("roles/dns/defaults/main.yml")
    dns_tasks = text("roles/dns/tasks/main.yml")
    dns_privacy_guard = text("roles/dns/tasks/privacy_guard.yml")
    if "substrate_service_domain" not in dns_defaults:
        failures.append("public-DNS privacy guard must cover the service domain")
    if "import_tasks: privacy_guard.yml" not in dns_tasks:
        failures.append("public-DNS reconciliation must import the privacy guard")
    for required in (
        'loop: "{{ dns_records_present }}"',
        "dns_forbidden_domains | map('regex_escape') | join('|')",
        "dns_record_fqdn",
        "ignorecase=true",
    ):
        if required not in dns_privacy_guard:
            failures.append(f"public-DNS privacy guard is missing {required!r}")

    if failures:
        raise SystemExit("DNS contract failures:\n- " + "\n- ".join(failures))

    print("DNS architecture contract passed.")


if __name__ == "__main__":
    main()
