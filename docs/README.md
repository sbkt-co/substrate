# Documentation index

Where to look, by the question you are asking:

- [architecture.md](architecture.md) — How is substrate put together and why? The repo layout, execution flow, topologies, and the design invariants.
- [runbook.md](runbook.md) — How do I actually operate the fleet? The three day-to-day workflows: change config, add a machine, seed/rotate a secret.
- [secrets.md](secrets.md) — Where do secrets live and how are they seeded, consumed, and rotated? The node-local files model and its blast radius.
- [../README.md](../README.md) — What is substrate? The top-level overview, environments/promotion, network+TLS design, and quickstart.
- [../CONTRIBUTING.md](../CONTRIBUTING.md) — How do I propose a change? PR rules, CI gates, fast-forward promotion, and how to add a role.
- [../staging/README.md](../staging/README.md) — How does the persistent Incus staging fleet work? Bring-up, secrets seeding, and lifecycle.
- [../tests/README.md](../tests/README.md) — How do I validate a change? The containerized lint suite and the Incus real-convergence harness.
