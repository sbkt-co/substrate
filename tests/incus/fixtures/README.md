# Incus converge test fixtures

Test-only material for the real converge test (`tests/incus/run.sh`).

## `test-secret.sops.yaml` (generated at test time — never committed)

To positively exercise the node-held-key SOPS decrypt path in `roles/common`
(`tasks/sops.yml` -> `sops_decrypt.yml`) — which is otherwise dead in CI, because
the ephemeral node is a registered recipient of nothing — `run.sh`:

1. installs `age` + the pinned `sops` release inside the container;
2. generates a **throwaway** age identity at `/etc/substrate/secrets/age.key`
   (mode `0600`) — the exact path `roles/common` expects, so the role's own
   `age-keygen` step no-ops on it;
3. encrypts a dummy `content: <value>` mapping to that key into
   `test-secret.sops.yaml`, placed under this directory's path **inside the
   container** (the decrypt task resolves `{{ playbook_dir }}/{{ src }}` and both
   stats and decrypts on the target, since the incus connection makes the
   controller and target different hosts).

`tests/incus/test-vars.yml` (loaded by `converge.yml` via `vars_files` AFTER
`group_vars/all.yml` — play `vars_files` outrank inventory vars, so this override
cannot live in `inventory.yml`) replaces `substrate_sops_secrets` with a single
entry pointing at this fixture, so `roles/common` decrypts it for real. `verify.yml`
then asserts the decrypted dest exists with mode `0600` and the expected content.

The private key never leaves the container and is never printed; the plaintext is
a dummy self-test value that protects nothing. The ciphertext is regenerated every
run and is `.gitignore`d — no secret material, real or dummy, is committed here.

## Known seam (documented, not worked around)

`roles/common/tasks/sops_decrypt.yml` hard-codes the ciphertext location as
`{{ playbook_dir }}/{{ sops_secret.src }}` and runs the decrypt on the **target**.
Over the incus connection the target is the container, whose filesystem does not
contain the controller's repo checkout. There is no role-level var to point the
decrypt at an alternate root without editing `roles/**` (out of scope for this
change). The harness therefore mirrors the controller-side playbook dir path
inside the container and drops the fixture there, which drives the unmodified role
code end-to-end. If the role later gained a configurable ciphertext root (e.g. a
`substrate_sops_src_root` default), this mirroring could be dropped.
