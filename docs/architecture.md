# Architecture

How `substrate` is put together and why. This is the map operators read before
touching the fleet. For day-to-day commands see [runbook.md](runbook.md); for the
contribution workflow see [../CONTRIBUTING.md](../CONTRIBUTING.md); for secret handling
see [secrets.md](secrets.md).

The one-paragraph model: GitHub is the control plane. Every node converges
*itself* by running `ansible-pull` on a systemd timer against the branch it
tracks (`main` = production, `staging` = pre-prod, promoted fast-forward only).
A node is bootstrapped once, then differentiated into its role by the `node_roles`
list in its `host_vars`. Internal addressing is a headscale tailnet; internal hosts
never appear in public DNS or CT logs. There is no operator laptop in the control
loop — the fleet reconciles itself from git. Where every name is answered — and the
move to neutral naming served by an internal resolver — is §8.

---

## 1. Repository structure — what each path is for

```
local.yml                 # ansible-pull entry point; run on every reconcile.
                          #   pre_tasks: load host_vars, read /etc/substrate/branch seed, pin substrate_branch
                          #   roles: common -> reconciler (always)
                          #   tasks: include_role loop over node_roles
ansible.cfg               # roles_path=roles, inventory=inventory/hosts.yml, become via sudo.
                          #   DELIBERATELY dependency-free: no community.* callbacks/plugins,
                          #   because it also governs ansible-pull on nodes that have only ansible-core.
inventory/hosts.yml       # localhost only (ansible_connection=local). Used by lint/syntax-check
                          #   and local ad-hoc runs; ansible-pull always targets the node itself.
group_vars/all.yml        # fleet-wide canonical vars: repo url, substrate_branch fallback,
                          #   reconcile interval/splay/on_boot, node_roles default [],
                          #   substrate_secrets_dir, substrate_domain/tailnet_domain,
                          #   substrate_headscale_url (''), substrate_acme_staging/email.
host_vars/<hostname>.yml  # per-node IDENTITY: node_roles list + safe overrides
                          #   (reconcile cadence, substrate_headscale_url, headscale_listen_addr).
                          #   The tracked branch is NEVER here (see below).
bootstrap/bootstrap.sh    # one-shot fresh-node bootstrap (cloud-init user-data). Installs git+ansible+age,
                          #   writes /etc/substrate/branch, creates /etc/substrate/secrets (0700),
                          #   generates the node age identity (age.key, prints only the PUBLIC key),
                          #   seeds secret files from env vars (fallback), exec's the first ansible-pull.

roles/common/             # base substrate every node gets: base packages, /etc/substrate state dir,
                          #   /etc/substrate/node.yml identity record, and SOPS secret distribution
                          #   (installs sops+age, decrypts committed secrets/*.sops.yaml the node holds a key for).
roles/reconciler/         # installs ansible, creates the checkout dir, installs three systemd units
                          #   (reconcile.service + failure-handler + timer), enables/starts the timer,
                          #   writes /etc/substrate/status.yml via ExecStopPost.

# Differentiation layers (selected per-node via node_roles):
roles/headscale/          # version-pinned .deb install of headscale, config render, service enable,
                          #   fleet user creation. Listens loopback-only by default.
roles/tailnet/            # tailscale apt repo + package, tailscaled service, guarded `tailscale up`
                          #   against headscale (needs authkey file + substrate_headscale_url + not already up).
roles/cert_issuer/        # certbot + dns-cloudflare plugin; issues the wildcard *.net.sbkt.co via DNS-01;
                          #   serves the live cert over the tailnet (python3 http.server bound to the
                          #   tailscale IPv4 on :8444).
roles/cert_client/        # fetches fullchain.pem + privkey.pem from the issuer over the tailnet;
                          #   writes to /etc/substrate/certs/. Skips loudly on failure, never fails converge.
roles/dns/                # reconciles the PUBLIC Cloudflare sbkt.co zone from git; privacy guard asserts
                          #   no *.net.sbkt.co names leak into public records. Self-installs community.general.

staging/                  # persistent 2-node Incus fleet in project substrate-staging (staging-core,
                          #   staging-web1). up.sh: instance lifecycle + seed + converge order + authkey mint.
                          #   converge.yml mirrors local.yml over the incus connection; inventory.yml uses
                          #   community.general.incus.
tests/                    # Dockerfile + entrypoint.sh = the validate suite (yamllint + ansible-lint +
                          #   syntax-check + check-mode converge). incus/run.sh = real converge + idempotence
                          #   + drift-repair. incus/verify.yml = assert units present + timer active.
                          #   incus/colima-up.sh = macOS-only Incus bootstrap via Colima.
```

**Why the branch is not in `host_vars`.** The tracked branch is seeded once at
bootstrap into `/etc/substrate/branch` and pinned by `local.yml`. Keeping it out
of `host_vars` means every `host_vars/<hostname>.yml` is byte-identical across
`main` and `staging`, which is what makes fast-forward promotion clean. Deriving
the branch from the repo would be circular. Move a node between environments by
rewriting `/etc/substrate/branch` (or re-bootstrapping).

---

## 2. Execution flow — first boot to steady-state

Single timeline, fresh node to reconcile loop:

```
t0  FIRST BOOT (cloud-init runs bootstrap/bootstrap.sh as root)
      - install git + ansible-core + age via the host package manager
      - write /etc/substrate/branch      <- SUBSTRATE_BRANCH  (the environment seed)
      - install -d -m 0700 /etc/substrate/secrets
      - generate node age identity (age.key 0600, PRIVATE never printed);
        print the PUBLIC key in a marked REGISTER-THIS-NODE-KEY block
      - seed secret files (0600) from env vars (FALLBACK): tailnet-authkey,
        cloudflare-dns.ini, cloudflare.ini   (values never logged; see secrets.md)
      - exec:  ansible-pull --url <repo> --checkout <branch> --purge -i localhost, local.yml

t0+  FIRST CONVERGE (local.yml)
      pre_tasks:
        - include_vars host_vars/<fqdn>.yml or host_vars/<hostname>.yml (skip if absent)
        - stat + slurp /etc/substrate/branch -> set_fact substrate_branch
        - debug: report resolved environment + node_roles
      roles (always, in order):
        - common     -> base packages, /etc/substrate/, node.yml identity record,
                        SOPS decrypt of committed secrets this node holds a key for
        - reconciler -> ansible install, checkout dir, 3 systemd units, enable+start timer
      tasks:
        - include_role loop over node_roles (headscale, tailnet, cert_issuer,
          cert_client, dns, and any future service roles)

t0+  TIMER INSTALLED  (substrate-reconcile.timer)
        OnBootSec=5min        OnUnitInactiveSec=15min (prod) / 5min (staging)
        RandomizedDelaySec=120s (prod) / 30s (staging)      Persistent=true

Δt   EVERY TICK  (substrate-reconcile.service)
        - ansible-pull, same args as bootstrap
        - TimeoutStartSec=10min guards a hung git fetch from wedging the node
        - --purge removes stale checkout files
        - --only-if-changed is INTENTIONALLY ABSENT: re-converge every tick so
          manual drift is repaired even when the branch has not moved
        - ExecStopPost: atomic write of /etc/substrate/status.yml (last_run, result, exit_status)
        - OnFailure=substrate-reconcile-failure.service (currently /bin/true;
          extension point for alerting)
```

What runs where: everything runs **on the node itself**, over the `local`
connection. There is no push, no bastion, no operator machine in the loop.

**Staging is the same flow with a different transport.** `staging/up.sh` drives
`staging/converge.yml` (a mirror of `local.yml`) over the `community.general.incus`
connection instead of `local`, with the same role ordering. `up.sh` controls
bring-up order — `staging-core` first (so headscale exists), then `staging-web1` —
and mints the tailnet preauth keys. Once the instances are live they run the
in-container reconciler timer like any other node; `up.sh` is then only needed to
(re)create instances or re-seed secrets.

---

## 3. The Colima boundary

```
+--------------------------------------------------------------+
|  macOS DEV MACHINE ONLY                                        |
|                                                                |
|   Colima profile "docker"  ->  Docker daemon  (lint image)     |
|   Colima profile "incus"   ->  Incus daemon   (node modeling)  |
|                                                                |
|   tests/incus/colima-up.sh sets up the "incus" profile;        |
|   the default docker profile is left untouched, so both        |
|   `docker` and `incus` CLIs work at once on a Mac.             |
+--------------------------------------------------------------+
        Colima exists NOWHERE else. It is a dev convenience only.

Linux (CI self-hosted runner, staging hardware, production VPS):
   Incus runs NATIVELY via `incus admin init`. No Colima. No Docker for Incus.
   The CI "Install Incus" step self-skips on self-hosted runners
   (guarded by runner.environment == 'github-hosted').

Production nodes:
   No Colima. No Docker. No container runtime at all.
```

- **Colima** is purely the macOS way to host an Incus daemon (and, separately,
  Docker) inside a VM. It never appears in staging, CI, or production.
- **Docker** is used for exactly one thing: building/running the lint toolchain
  image (`tests/Dockerfile`, the CI `validate` job). No Ansible role installs or
  uses Docker on any node.
- **Incus** models *nodes* (whole machines) for staging and tests. It is never an
  app runtime inside a production node.
- Both `staging/up.sh` and `tests/incus/run.sh` auto-detect the active remote via
  `incus remote get-default` (`colima-incus` on macOS, `local` on Linux); the same
  scripts run unchanged on both. `SUBSTRATE_INCUS_REMOTE` overrides.
  (Note: `tests/incus/inventory.yml` correctly defaults to `local`; a bare direct
  `ansible-playbook -i staging/inventory.yml` invocation on Linux should also
  export `SUBSTRATE_INCUS_REMOTE=local` — `up.sh` always exports it, so the normal
  path is safe.)

---

## 4. Single-VPS vs multi-VPS topologies

Roles are assigned per-node via `node_roles`. The same roles compose whether they
all land on one machine or spread across several. Fleet-singleton roles —
`headscale`, `cert_issuer`, and `dns` — must each be assigned to **exactly one**
node; `tailnet` goes on every node that joins the tailnet; `cert_client` on every
non-issuer node that needs TLS.

**Single-VPS — everything stacked on one node:**

```yaml
# host_vars/prod-core.yml
node_roles:
  - headscale     # coordination server (fleet singleton)
  - tailnet       # this node also joins its own tailnet
  - cert_issuer   # issues + serves the wildcard (fleet singleton)
  - dns           # reconciles the public zone (fleet singleton)
  - <service>     # whatever the box actually serves
```

Because the issuer and the clients are the same box, cross-node cert fetch is a
non-issue. `headscale` still listens loopback-only by default; front it with a
reverse proxy or firewall if clients outside the box must reach it, and set
`substrate_headscale_url` to a reachable address.

**Multi-VPS — the reference shape (what staging models):**

```yaml
# host_vars/prod-core.yml   (coordination + issuer)     e.g. staging-core
node_roles: [headscale, tailnet, cert_issuer]
substrate_headscale_url: "https://headscale.<reachable-endpoint>"   # public, clients reach this

# host_vars/prod-web1.yml   (service node)              e.g. staging-web1
node_roles: [tailnet, cert_client]
cert_client_issuer_host: "prod-core.net.sbkt.co"   # MUST override: the issuer's MagicDNS name
```

Assign `dns` to one stable node (often the core). Every service node fetches the
wildcard from the issuer over the tailnet.

**Important overrides that are not obvious:**

- `substrate_headscale_url` defaults to `''` fleet-wide. **A production headscale
  node must set it explicitly** (in that node's `host_vars` or `group_vars`) to an
  address clients can reach *before* the tailnet is up. Left empty, the headscale
  config renders a MagicDNS fallback URL that cannot resolve pre-tailnet, and
  `tailnet` enrolment skips with a warning — a silent first-bring-up gap.
- `cert_client_issuer_host` has **no fleet-wide default** (`''`), because which
  node runs `cert_issuer` differs per topology. **Every `cert_client` node must
  set it** in `host_vars` to the issuer's MagicDNS name (e.g.
  `staging-core.net.sbkt.co`); left empty, `cert_client` skips the fetch with a
  loud warning rather than failing.
- `headscale_listen_addr` defaults to `127.0.0.1:8080` (loopback-only), which is
  correct for production. Staging widens it to `0.0.0.0:8080` because Incus-bridge
  peers reach it before the tailnet exists — this is a documented staging-only
  exception, not a production pattern.

**Migration 1 -> N:** add `host_vars/<new-hostname>.yml` with the right
`node_roles`; bootstrap the new node with `SUBSTRATE_TAILNET_AUTHKEY` seeded; the
node discovers its own identity and joins the tailnet on its first pull. Move
`cert_issuer`/`headscale`/`dns` off the original box by editing `node_roles` on
both machines (add on the new node, remove on the old). No central orchestrator
is involved; each node reconciles itself into the new layout on its next tick.

---

## 5. Building on the substrate — adding a service role

Checklist for a new `roles/<service>/`:

1. **`defaults/main.yml`** — all role-local vars with documented defaults. Never
   redefine fleet-wide vars from `group_vars/all.yml`. Any value that must differ
   per environment (e.g. an issuer host) gets a safe default and is overridden in
   `host_vars`.
2. **`tasks/main.yml`** — install with `ansible.builtin.package`/`apt` (`state:
   present`); prefer modules with real `state:` semantics over `command`/`shell`.
   - Guard every systemd-touching task with `when: ansible_service_mgr ==
     'systemd'` (load-bearing: it lets the unprivileged check-mode converge pass in
     a plain container while still installing/starting units on real nodes).
   - For secrets: `stat` the file, then `debug` + skip loudly if absent — **never
     fail the converge**. `no_log: true` on any task touching secret content.
   - Any unavoidable `command`/`shell` gets `creates:` / `changed_when:` / `when:`.
   - If you need a community collection, self-install it with a `creates:` guard the
     way `roles/dns` does — do not add it to `ansible.cfg` (which must stay
     dependency-free for `ansible-core`-only nodes).
3. **`handlers/main.yml`** — restart-on-config-change handlers, likewise guarded
   with `ansible_service_mgr == 'systemd'`.
4. **Wire it** — add the role to `node_roles` in the relevant
   `host_vars/<hostname>.yml`, plus any required var overrides.
5. **Verify playbook** — extend `tests/incus/verify.yml` to assert the unit files
   exist and the service `ActiveState == 'active'`.
6. **Gate locally** — `tests/run.sh` (lint + syntax + check-mode, no privileges),
   then `tests/incus/run.sh` (real converge + idempotence, needs Incus).
7. **Promote** — feature branch -> PR -> merge to `staging` -> soak on the staging
   fleet -> promote to `main` via `git merge --ff-only staging`. Note: the CI
   `converge` job is gated (it runs on `workflow_dispatch`, on PRs labelled
   `needs-converge`, and on pushes to `main`/`staging` that touch
   reconciler-relevant paths); a role change should carry the `needs-converge`
   label so real convergence is actually exercised before merge.

Conventions: idempotent by construction; secrets read from
`{{ substrate_secrets_dir }}` with graceful skip; no workstation-side state.

---

## 6. Secrets

Roles read node-local files under `/etc/substrate/secrets` (dir `0700`, files
`0600`), fresh on every converge. Values ride git only as **SOPS ciphertext
encrypted to node-held age keys**: each node generates its own age identity at
bootstrap (`age.key`, never leaves the node), and `roles/common` decrypts the
committed `secrets/*.sops.yaml` it is a recipient of — driven by the
`substrate_sops_secrets` manifest — into those dest files. Workstation-held decrypt
keys stay banned (laptop-off invariant); the operator workstation only *encrypts*
(public-key) via `scripts/secret.sh`. Bootstrap env-var / manual seeding remains a
supported fallback for not-yet-registered nodes. Scoping, rotation, blast radius,
the SOPS carve-out, and the graduation path are covered in
**[secrets.md](secrets.md)**.

---

## 7. Topology at each layer

**Physical**

```
Production:  OVH VPS, Debian trixie (13, Python 3.13).
             No provisioning layer in this repo yet (deliberate) — VPS created out of band.
Staging:     persistent Incus system containers on owned/local hardware
             (project substrate-staging). Not cloud, not Colima.
Dev/CI:      macOS -> Colima+Incus;  Linux runner -> native Incus.
```

**Network**

```
Public internet   : OVH VPS public IPs. Internal hosts get NO public DNS records.
Tailnet (CGNAT)   : headscale-assigned 100.64.0.0/10 (v4), fd7a:115c:a1e0::/48 (v6).
                    THE internal fleet network; all inter-node traffic rides it.
Incus bridge      : dev/staging only, internal to the host. Provides *.incus names
                    (e.g. staging-web1 reaches headscale at staging-core.incus:8080
                    BEFORE it has joined the tailnet). Not present in production.
```

**Naming**

```
Public DNS   : Cloudflare-managed sbkt.co zone, reconciled from git by roles/dns.
               Public records only (apex A/CNAME/MX/TXT). A privacy guard asserts
               no *.net.sbkt.co names leak in.
MagicDNS     : headscale-managed net.sbkt.co. Resolves <hostname>.net.sbkt.co ->
               tailscale IP. Internal topology never appears in public DNS or CT logs.
```

The full resolution path (where each lookup goes), the internal CoreDNS resolver,
and the move to neutral `sbkt.co` naming are in **§8** — this block is the built
state that §8's *Current vs target* migrates from.

**TLS**

```
One wildcard cert: *.net.sbkt.co (+ net.sbkt.co), issued by the cert_issuer node
                   via certbot DNS-01 against Cloudflare.
Distribution     : issuer serves the live cert over the tailnet (python3 http.server
                   bound to the tailscale IPv4 on :8444); cert_client nodes pull it to
                   /etc/substrate/certs/. Cert + key only ever travel the encrypted tailnet.
ACME endpoint    : substrate_acme_staging=true -> Let's Encrypt STAGING (untrusted, no
                   rate-limit exposure) until explicitly flipped to false for real certs.
```

**Control plane**

```
GitHub branches: main (production) and staging (pre-prod). Nodes pull via ansible-pull.
                 The tracked branch is seeded once at bootstrap into /etc/substrate/branch
                 and never changes unless an operator rewrites it. main and staging are
                 kept strictly fast-forward-related so environments never diverge.
```

---

## 8. DNS resolution — where names are answered

This section captures the DNS design and, specifically, **where a given lookup
goes**. It records a decided direction; part of it is the target the fleet is
migrating to — see *Current vs target* at the end.

### Three name spaces, three authorities

| Name space | Example | Authoritative source | Resolvable where |
|---|---|---|---|
| Public | `www.sbkt.co` | Cloudflare (`sbkt.co` public zone, reconciled by `roles/dns`) | Public internet; visible in CT logs |
| Internal service | `s3.sbkt.co`, `web1.sbkt.co` | **internal resolver** (CoreDNS, git-managed zone) | Only on the tailnet |
| MagicDNS host | `web1.<tailnet-base>` | headscale (control-server data) | Only on the tailnet |

Internal names carry **no transport label** — services are plain `<name>.sbkt.co`,
not `<name>.net.sbkt.co`. The `.net.` label that encoded "this is the tailnet
transport" is retired: it leaked transport structure into the one public artifact
(the CT-logged wildcard) for no benefit.

### The resolver path — where a lookup goes

Nodes use **one resolver: CoreDNS**, reached over the tailnet. headscale points
every node at it (see *coordination* below), so a node's stub resolver targets
tailscale's local proxy (`100.100.100.100`); `tailscaled` answers MagicDNS host
names itself and forwards everything else to CoreDNS, which answers internal names
authoritatively and forwards the rest to public upstreams **over DoT**:

```
app on a node
  -> 100.100.100.100  (tailscaled; headscale set global-resolver = CoreDNS, override_local_dns)
       -> MagicDNS host name (<host>.<magic-base>)  -> answered locally by tailscaled
       -> everything else                            -> CoreDNS @ <core tailnet IP>
                                                            |
                        internal record (s3.sbkt.co)  -> answered from the git zone (A/AAAA/CNAME/SRV/TXT)
                        any other name (www.sbkt.co…) -> fallthrough -> forward over DoT
                                                            to tls://1.1.1.1, tls://1.0.0.1
```

CoreDNS Corefile shape — apex split-horizon via `fallthrough`, encrypted forward:

```
sbkt.co {
    hosts /etc/coredns/internal.zone { fallthrough }   # internal name miss -> fall through
    forward . tls://1.1.1.1 tls://1.0.0.1 { tls_servername cloudflare-dns.com }
}
. {
    forward . tls://1.1.1.1 tls://1.0.0.1 { tls_servername cloudflare-dns.com }
}
```

Consequences, stated plainly:

- **Internal names never leave the tailnet** — answered from the git zone over
  WireGuard; no public resolver, Cloudflare, or on-path observer sees the query.
- **Public names still resolve on-tailnet** — `fallthrough` is what lets a public
  `sbkt.co` name pass the internal-zone block instead of NXDOMAIN'ing; CoreDNS then
  forwards it. Without `fallthrough`, being authoritative for `sbkt.co` would make
  CoreDNS answer NXDOMAIN for `www.sbkt.co`.
- **The CoreDNS→upstream hop is the only public egress, and it is DoT-encrypted**, so
  on-path observers see neither internal names nor your public lookups in cleartext.
  All public lookups also egress behind one resolver IP, aggregating per-node query
  metadata rather than exposing it.
- **Off the tailnet a client never gets the internal IP** — it can't reach CoreDNS and
  no public internal record exists; internal addressing stays a tailnet-only fact.
- **Before the tailnet is up** (fresh boot, or the Incus-bridge bootstrap window) a
  node uses its default resolver — the cloud provider's, or the Incus bridge's
  `.incus` names in dev/staging (this is how `staging-web1` reaches headscale at
  `staging-core.incus` *before* it has joined the tailnet). Once `tailscaled` enrolls,
  headscale's DNS config repoints it at CoreDNS.

**Resilience.** CoreDNS is now on the path for *every* lookup, not just internal — a
harder singleton than a split-DNS design (where public names would still resolve if
CoreDNS died). Mitigate by running **two CoreDNS instances**, listed as two global
nameservers rendering the same git zone, so a node fails over; or accept the SPOF and
lean on client-side (`systemd-resolved`) caching to ride out short blips.

### Why an internal resolver, not just MagicDNS

MagicDNS answers only host names (`A`/`AAAA`) from control-server data; it is not an
authoritative zone server, so it cannot express `CNAME`, `SRV`, `TXT`, `MX`, or
service aliases. **CoreDNS** is a single-binary systemd service (fits §9),
authoritative for the internal zone from a **git-managed zone file**, giving the full
record-type set while staying entirely on the tailnet. It is a fleet-singleton
`resolver` role.

### How CoreDNS coordinates with headscale

There is **no live DNS link** between them — headscale runs no DNS server for CoreDNS
to forward to. Coordination is two one-way, git-driven flows:

1. **headscale → nodes (pointing them at CoreDNS).** `roles/headscale` renders the DNS
   config block — `nameservers.global = [<core tailnet IP>]`, `override_local_dns: true`
   — and headscale pushes it to every enrolled node. This is what makes CoreDNS the
   fleet's resolver; it is pure headscale config in git.
2. **headscale's node data → CoreDNS's zone (so it can answer host records).** CoreDNS
   needs node→tailnet-IP to serve `web1.sbkt.co`; headscale owns those assignments. Two
   supported ways to get them into the zone:
   - **Generated (recommended):** co-locate CoreDNS on the headscale (core) node; the
     `resolver` role runs `headscale nodes list -o json` locally at converge and
     templates `/etc/coredns/internal.zone`, reloading CoreDNS on change. The zone
     tracks membership automatically on the reconcile timer.
   - **Static:** pin each node's stable tailnet IP in the git zone file (recorded at
     `add-node` time). Fully declarative, no runtime coupling; headscale IPs are stable
     per node, so the pin holds until a node is deleted/re-registered.

Because CoreDNS *consumes* headscale's data (rather than headscale calling CoreDNS),
**co-locating the two singletons on the core node is the natural layout** — the
generator has local CLI/DB access, and the core's tailnet IP (baked into every node's
resolver config) is one stable value to pin. Service aliases and rich records
(CNAME/SRV/TXT that MagicDNS can't express) are hand-added to the same git zone; host
`A`-records come from the generator or MagicDNS. A second CoreDNS for resilience
renders the same zone from the same data.

### Privacy — what an outside observer can and cannot see

- **Cloudflare** holds only public `sbkt.co` records; the internal zone is never
  published there, so internal names cannot be enumerated from public DNS.
- **CT logs** show only the neutral wildcard `*.sbkt.co`. Internal hosts are covered
  by that wildcard, so **no per-host certificate is ever issued** and individual
  internal names never enter CT. The apex wildcard base is semantically empty — it
  discloses nothing about transport or internal structure.
- **DNS does not expose the label at all.** A wildcard match creates no per-name
  record; only a connection-terminating endpoint learns the name — caddy via the TLS
  **SNI** (cleartext in the ClientHello) and the HTTP **Host** header. `sshd` never
  learns it (SSH carries no hostname; the server sees only source IP + username).
  The one residual leak is a client resolving an internal name **off the tailnet**
  (e.g. browser DoH bypassing the tailnet resolver) — contained by keeping internal
  names to on-tailnet use and disabling DoH on managed devices.

### TLS key placement — the actual security control

The wildcard's privacy is a property of the *name*; its security is a property of
*where the private key lives*. Wildcard **scope** (apex `*.sbkt.co` vs. a scoped
`*.x.sbkt.co`) does not change how hard the key is to steal, and co-located keys
fall together — so scoping is not itself a control. The control is **minimizing
where the key is deployed**: the public-trusted wildcard key belongs on the
**public edge (caddy) only**. Internal service-to-service traffic already rides
WireGuard (encrypted and mutually authenticated), so internal nodes do not need the
public wildcard at all — where they terminate TLS internally, a self-signed or
future internal-CA leaf suffices. This retires the old serve/fetch fan-out of the
wildcard key to every `cert_client` node, which was the only thing that made
wildcard scope matter for blast radius.

### Current vs target

- **Built today:** headscale MagicDNS under `net.sbkt.co`; wildcard `*.net.sbkt.co`
  issued by `cert_issuer` and fetched by `cert_client` nodes over the tailnet
  (§7 TLS). Internal names are `<host>.net.sbkt.co`. The **`resolver` role now
  exists** — it installs CoreDNS on the core node (version-pinned binary, systemd
  unit binding loopback + the tailnet IPv4), renders the Corefile above, and
  generates `/etc/coredns/internal.zone` from `headscale nodes list` on every
  reconcile (skipping loudly, leaving any prior zone in place, when the headscale
  CLI is absent or not yet answering). It is **not yet on the resolution path**:
  the headscale wiring is gated behind `substrate_resolver_wire_dns` (default
  `false`), so a node's DNS still points at the default global resolvers until the
  fleet is explicitly cut over.
- **Target (this design):** neutral naming under `sbkt.co` (no `.net.` label); the
  `resolver` singleton **wired in** — `substrate_resolver_wire_dns: true` with
  `substrate_resolver_address` pinned to the core node's tailnet IPv4, so headscale
  points every node at CoreDNS with `override_local_dns` (split-DNS for full record
  types); wildcard `*.sbkt.co`; the wildcard key confined to the public edge.
  Remaining migration is a rename of the tailnet base domain, flipping the wiring
  var, and reissuing the wildcard at the apex; the `host_vars` references to
  `*.net.sbkt.co` names move to the neutral zone in the same change.

---

## 9. Identity and access — planes, not a spine

The design that survived the adversarial review. **The tailnet is the internal trust
boundary.** An earlier draft made a CA (`step-ca`) the "spine"; it is now **deferred**,
because it re-solved problems the tailnet already solves and its two concrete day-one
jobs did not hold up (below). Like §8, this records a decided direction — none of this
plane is built yet.

### The two planes

**Internal plane — services talking to services (machines).**

- **Identity + encryption: the tailnet (WireGuard).** A packet from `100.64.x` provably
  came from a headscale-enrolled node, and the traffic is already encrypted and mutually
  authenticated. No app-layer mTLS is stacked on top.
- **Authorization: headscale ACLs** (huJSON policy in git) + a handful of **git-declared
  service uid/gids**.
- **S3 (versitygw): native access keys** (SigV4), delivered as node-local secrets via the
  existing SOPS/age pipeline; per-account quotas on versitygw. A certificate is *not* an
  S3 principal — S3 has no cert-auth path — so identity at most bootstraps/rotates the key.
- **NFS: host-based exports** over the tailnet + git-declared service uids. This is
  per-*host* trust (a root process on a client host can assume any local service uid), not
  per-service enforcement — named honestly; per-service would require Kerberos.

**Public plane — humans and inbound webhooks (off-tailnet).**

- **caddy** is the sole public front door: TLS termination + routing + per-route auth.
- **Authelia** (file backend + SQLite) is the OIDC provider for human web SSO, 2FA
  enforced. It is the **only** publicly-exposed identity component.
- **Public SSH apps** (ping.sh-style) **own their identity** on the client pubkey; no CA
  — forcing a CA-issued cert there would kill the zero-setup `ssh host` product.

### Three authorization modes at the caddy edge

| Mode | Who | Mechanism |
|---|---|---|
| OIDC | humans → web apps | Authelia |
| Capability / HMAC | inbound webhooks (smee.io-style) | per-source HMAC over body+timestamp, replay window; secret node-local |
| mTLS / SPIFFE | internal service-to-service | **not used at the edge** — internal traffic rides the tailnet, never caddy |

The webhook mode's real work (per-channel secret provisioning, SSE streaming through
caddy, channel-ownership authz, capability revocation) lives in the app, not in an
"auth mode."

### Operator access

Operator shell is **Tailscale SSH** brokered by headscale ACLs (identity = tailnet node
owner), plus a **non-CA break-glass key** so cert/tailnet trouble can never lock the sole
operator out of the box they need to fix.

### What's deferred, and the trigger to revisit

- **step-ca** — no day-one job once SSH → Tailscale SSH, S3 → native keys, and internal
  mTLS → redundant on WireGuard. Revisit only for (a) mutually-distrusting workloads
  co-located on one host, or (b) authenticated service mTLS *off* the tailnet. If it
  returns: keep it **tailnet-only** (never public), **offline root + short intermediate**,
  and pre-stage the next root in a trust bundle so rotation is a pull-model overlap, not a
  flag day.
- **LLDAP** — deferred until a human directory / self-service genuinely arrives. Authelia's
  file backend covers a provisioned user set; self-registration is the one thing it can't
  config into, and LLDAP-behind-Authelia is the non-destructive next rung (services trust
  OIDC, not a product, so the IdP stays swappable).

### Cross-cutting rules (non-negotiable, from the security + ops review)

1. **Never commit — even SOPS-encrypted — anything not cleanly revocable:** password
   hashes, any signing key, S3 secret keys, HMAC secrets. Node-local `0600`, like the
   existing secret model. Git holds the *spec* (ACL policy, principal→host maps, public
   certs, service uids), never these values. See [secrets.md](secrets.md).
2. **Stateful singletons need a restore story pull-converge can't provide.** headscale's DB
   (tailnet membership) and Authelia's WebAuthn/TOTP registrations are runtime state — not
   in git, not reconstructible from it. Back them up age-encrypted to S3 (versitygw),
   **restore-if-empty / never-reinit**, and prove the dead-singleton restore in the Incus
   staging harness (today's core-first `up.sh` can't exercise it — that gap is the test to
   add).
3. **Route every new failure signal through the mechanisms already built** — `OnFailure` +
   `/etc/substrate/status.yml` — so 3am triage stays one `cat status.yml` (add
   `clock_synced`, `tailnet_up`, `oidc_backend_reachable`, `last_backup`, …). Keep
   dependency ordering **skip-loudly**, never converge-failing.

### Current vs target

- **Built today:** none of this plane exists — the fleet has the tailnet, cert
  distribution, and the reconcile loop only.
- **Target (this design):** headscale ACLs as internal authz; versitygw with native keys;
  host-based NFS; caddy public edge; Authelia OIDC (public, 2FA); Tailscale SSH +
  break-glass for operators; step-ca and LLDAP deferred. Build order is a separate decision
  (caddy-first is the recommended first slice — it unblocks serving anything without
  committing to Authelia or S3).

---

## 10. Node differentiation policy — systemd-native first

**Stance.** Prefer **systemd-native processes installed by roles**. Single-binary
services (headscale, tailscaled, a versitygw-style daemon) fit this cleanly: the
role installs the binary/package and manages a systemd unit. **Containerize a
service only when packaging or isolation genuinely demands it** — and then use
**podman + systemd units** (quadlets), never a Docker daemon on the node. **Incus
system containers model whole NODES** (staging fleet, test harness); they are never
an app-layer runtime inside a production node.

This is not aspirational — it matches every role in the repo today:

| Component        | How it runs                                              | Container? |
|------------------|----------------------------------------------------------|------------|
| headscale        | version-pinned `.deb`, `headscale` systemd service       | no         |
| tailscaled       | official apt package, `tailscaled` systemd service       | no         |
| certbot (issuer) | CLI run one-shot with a deploy hook by the role          | no         |
| cert serve       | python3 http.server under a `substrate-certs` systemd unit | no       |
| dns              | `community.general` cloudflare module, no daemon         | no         |
| resolver         | version-pinned CoreDNS binary, `coredns` systemd service | no         |
| reconciler       | `ansible-pull` via a systemd oneshot + timer             | no         |

No production role installs Docker, podman, or any container runtime. Docker
appears **only** in `tests/Dockerfile` (the lint toolchain image, `validate` job).
Incus appears **only** in `staging/` and `tests/incus/` (node modeling). Nothing
in the repo contradicts this stance — hold the line when adding roles: default to
a systemd unit, and justify any container in the PR.
