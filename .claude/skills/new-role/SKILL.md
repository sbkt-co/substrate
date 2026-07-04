---
name: new-role
description: Scaffold a new Ansible differentiation role under roles/. Use when adding a new service role or node layer to substrate.
---

# New service role

Roles are the differentiation layer; a node selects them via `node_roles`. Do
not hand-write the skeleton — run the scaffold so the load-bearing patterns
(FQCN modules, the `when: ansible_service_mgr == 'systemd'` guard, the
skip-loudly secret stat with `no_log`, quoted file modes, a guarded restart
handler) are present and correct.

Steps:

1. Scaffold from templates (refuses to overwrite an existing role):

   ```sh
   scripts/new-role.sh <role_name>
   ```

   This writes `roles/<name>/{defaults,tasks,handlers}/main.yml` from
   `scripts/templates/role/`.

2. Edit the `TODO` markers in `tasks/main.yml` and `defaults/main.yml` for the
   real package/service/secret. Delete the secret block if the role needs none.

3. Gate locally:

   ```sh
   tests/run.sh
   ```

4. Wire it in: add `<role_name>` to `node_roles` in the relevant
   `host_vars/<hostname>.yml`, plus any required overrides.

See docs/architecture.md section 5 for the full new-role checklist (verify playbook,
convergence gate, `needs-converge` label, promotion).
