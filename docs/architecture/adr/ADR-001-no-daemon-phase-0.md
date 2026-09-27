# ADR-001: No backend daemon in Phase 0

Date: 2026-09-26
Status: Accepted

## Context

Opencode-style split was considered: a backend daemon (the engine) with
thin clients (GUI, CLI, TUI) talking to it over IPC.

## Decision

Phase 0 keeps the **in-process** plugin architecture (melos packages,
import-linter-enforced). No daemon. No wire protocol.

## Rationale

- The backends are **already daemons** — snapd, packagekitd. Our own
  daemon would be a second IPC hop that solves nothing new in Phase 0.
- Crash recovery is covered by backend-native recovery + the `restoring`
  state (see `operation-state-machine.md` §9). The 80% case needs no daemon.
- A daemon buys a wire protocol to version, a process lifecycle to manage
  (autostart, socket activation, daemon crashes), and two-process debugging
  — large cost before any user-visible win.
- Strangler-fig migration of the existing Flutter app favors in-process
  packages over process extraction. Smaller diff, cleaner rebase.

## The seam (the important part)

`store_host` — `UnifiedCatalog`, `OperationEngine`, `FeatureFlags` — is a
narrow interface boundary with **zero Flutter imports**. If a daemon is ever
wanted, we put a transport (D-Bus / gRPC / REST+WS) behind these same
interfaces. The split becomes a **deployment decision, not a rewrite**.

Process boundary later, interface boundary now.

## Revisit when

- Headless/scheduled updates without a GUI become a requirement, or
- a first-class CLI (`lcs install vlc`) needs to share one live engine
  with the GUI instead of shelling out to backends directly.
