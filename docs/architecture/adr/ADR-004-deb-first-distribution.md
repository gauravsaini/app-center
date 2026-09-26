# ADR-004: Native deb-first distribution

Date: 2026-09-26
Status: Accepted

## Context

Confinement matrix (from feasibility research):

- A **strict snap** cannot operate host Flatpak — no interface grants
  arbitrary host `flatpak` execution or system-bus access.
- `snapd-control` is super-privileged; a renamed community snap needs
  reviewer approval with no guaranteed precedent.
- A **Flatpak** of the store needs broad host access that Flathub reviewers
  must be convinced to grant.

## Decision

Phase 0 ships as a **native deb** (PPA) first: full host access to the snapd
socket, PackageKit D-Bus, and the flatpak CLI with zero confinement fights.

## Rationale

Lowest friction to prove the thesis. Confinement is a distribution problem,
not an architecture problem — don't let it shape Phase 0 code.

## Consequences

- Later vehicles: Flathub submission (permissions justified), COPR/AUR/Nix
  packaging. Classic/custom snap only if a sponsor path appears.
- Trademark: no "Ubuntu" in the software title. Descriptive "for Ubuntu"
  compatibility language is safer.

## Revisit when

A confinement story is proven for another vehicle, or a store/sponsor
approval path opens up.
