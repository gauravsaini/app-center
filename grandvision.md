# Grand Vision: One Store for All of \*nix

> Every \*nix user opens **one** store, searches **once**, installs **anything**.
> Like Homebrew did for macOS. Like Apple's App Store did for iOS.
> But **libre**, and **better**.

---

## The Dream

A kid installs Ubuntu, Fedora, Arch, or NixOS. She opens the store. She types
"video editor". She gets **one** honest list — native packages, Flatpaks, Snaps,
AppImages — with ratings, screenshots, and a single Install button. It just
works. Updates come from one place. Permissions are visible before install.

No one asks "which package format should I use?" ever again. That question is
a bug, and we are the fix.

## The Problem: Fragmentation

- Every distro speaks its own tongue: `apt`, `dnf`, `pacman`, `zypper`, `apk`,
  `nix`, `guix`. Same app, seven rituals.
- Even inside **one** distro there are four stores in a trench coat: deb vs
  snap vs Flatpak vs AppImage. Four update mechanisms. Four permission models.
  Four answers to "how do I install VLC?"
- Each world has its own half-broken GUI — or none. Search is bad. Reviews are
  scattered. Curation is whoever shouted last.
- The new user's first Linux question is always *"how do I install X?"* and the
  answer is always five conflicting forum posts.

Fragmentation is not freedom. Freedom is **choice without confusion**.

## What We Steal from Homebrew

- **One command, one index.** Homebrew didn't ask Apple for permission. It sat
  on top of macOS and made installing things trivial. Community formulae did
  the rest.
- Lesson: **unify the UX, don't fight the OS.** We don't replace `apt` or
  `dnf` — we make them invisible.

## What We Steal from Apple's App Store

- **One trusted place.** Curation, one-click install, automatic updates,
  sandboxing by default. Normies won because friction lost.
- Lesson: **trust + curation + zero-friction UX wins users.**
- What we reject: the walled garden, the 30% tax, the review gatekeeping, the
  single company that can pull your app overnight.

## The Libre + Better Promise

- **Libre:** GPL forever. Forkable by design. No single company controls the
  index, the client, or the roadmap. If we ever go evil, you fork us — that's
  the guarantee, in writing.
- **Better:** faster than anything before it (measured, not claimed),
  multi-backend from day one, honest UI — no ads, no dark patterns, no
  snap-first bias, no "recommended" that means "sponsored".

## The Strategy: Beachhead → Expansion

We don't boil the ocean. We take one beachhead and expand.

- **Phase 0 — The fork (now).** Fork Ubuntu's App Center. Three backends, one
  store: **snap + deb + Flatpak**, behind a plugin interface. Prove the
  architecture. Prove the UX. This is the Brave move: small delta, clean
  rebase, upstream improvements for free.
- **Phase 1 — More backends.** AppImage, and whoever shows up next, as plugins.
  If it installs software on Linux, it plugs into the store.
- **Phase 2 — Beyond Ubuntu.** The store runs on any distro and adapts: on
  Fedora it speaks `dnf` + Flatpak, on Arch `pacman` + AUR helpers, on NixOS
  `nix`. Same UI everywhere. The distro becomes a backend detail.
- **Phase 3 — The index.** A community-curated, distro-agnostic app metadata
  index — screenshots, descriptions, ratings, permissions — owned by no one,
  mirrored by everyone. This is the moat no company can buy.

## Principles

1. **Plugin everything.** Core stays tiny; every backend, every source is a
   plugin. (Learned from DeepSeek Harness: *everything is a plugin.*)
2. **Measure everything.** Startup time, search latency, install success rate —
   CI gates, not slogans. "Better" is a number or it didn't happen.
3. **Small delta, clean rebase.** The Brave model. Our fork's diff stays
   reviewable; upstream's work flows to us for free.
4. **Libre forever.** GPL. No proprietary backend, no CLA that steals your
   code, no rug-pull possible by construction.
5. **No dark patterns.** No ads, no sponsored placement disguised as
   "recommended", no scaring users away from formats we dislike. The store
   serves the user, not a packaging agenda.

## Non-Goals

- We do **not** replace `apt`/`dnf`/`pacman`/`nix`. We unify their UX.
- We do **not** build a proprietary store backend or take a cut of anything.
- We do **not** fight distros. We sit on top and make them all feel like one.
- We do **not** chase feature parity with upstream's every whim — the delta
  stays small and deliberate.

## The One-Line Pitch

**The App Store for \*nix — every format, one search, libre forever.**

---

*This is the sapna. Everything we build — every branch, every plugin, every
benchmark — must answer one question: does this get us closer to one store
for all of \*nix? If not, it doesn't ship.*
