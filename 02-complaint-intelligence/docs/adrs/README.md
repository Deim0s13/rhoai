# Architecture Decision Records

Decisions that shaped this use case, recorded when they were made, in the order
they were made. ADRs are never edited to change history; a superseded decision
gets a new ADR that references the old one.

| ADR | Title | Status |
|---|---|---|
| [0001](ADR-0001-independent-build.md) | Build independently of parallel control-plane work, design for low-cost convergence | Accepted |

## Format

Each ADR uses four sections: **Status**, **Context** (the forces at play),
**Decision** (what we chose, stated actively), and **Consequences** (what becomes
easier, what becomes harder, what new obligations follow).

Expected near-term ADRs, reserved here so numbering stays stable:

- ADR-0002: Platform baseline as validated in the provisioned environment
  (RHOAI version, operator availability, capability gaps against design)
- ADR-0003: Gateway layer composition
- ADR-0004: Tracing and evaluation conventions (span naming, MLflow structure)
