# Grand Vision: One Store for All of \*nix

> Every \*nix user opens **one** store, searches **once**, installs **anything**.
> Like Homebrew did for macOS. Like Apple's App Store did for iOS.
> But **libre**, and **better**.

---

## The Dream

A kid installs Ubuntu, Fedora, Arch, or NixOS. She opens the store. She types
"video editor". She gets **one** honest card per app — not three entries for
three formats — with ratings, screenshots, permissions, and a single Install
button. It just works. Updates come from one place. Permissions are visible
before install.

No one asks "which package format should I use?" ever again. That question is
a bug, and we are the fix.

## The Core Thesis: Reinvent, Don't Wrap

Anyone can call three APIs and put them in tabs. GNOME Software did it.
That's not the dream — that's a wrapper.

Wrapping asks: "how do I show snap results next to Flatpak results?"
Reinventing asks: "what IS an app, when it exists in three formats at once?"
And answers: **one app, one card** — the format is a detail, like a download
mirror.

We use the APIs — snapd, PackageKit, Flatpak — because reinventing the
plumbing would be madness. But everything the user touches, we rethink:

- **Identity:** the store thinks in *apps*, not packages. Three formats, one
  `UnifiedApp`. No one should ever see "VLC" three times.
- **Operations:** installing is not "fire a command and poll". It's a
  cancellable state machine with honest progress and typed errors.
- **Trust:** permissions are shown *before* install, not buried in a wiki.
  Trust is designed, not documented.
- **Discovery:** "video editor" should one day answer "I want to edit video"
  with a curated stack — not a package list. Search is the starting line.
- **Metadata:** consuming AppStream is wrapping; the community index
  (Phase 3) is reinventing — a metadata layer owned by no one.

The test for every feature: *did we rethink it, or did we just wire the API
to a button?* Wrappers don't ship.

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
- **Better:** faster than anything before it (measured, not claimed);
  **reinvented, not wrapped** — one app per card, operations you can cancel,
  permissions before install; honest UI — no ads, no dark patterns, no
  snap-first bias, no "recommended" that means "sponsored".

## The Strategy: Beachhead → Expansion

We don't boil the ocean. We take one beachhead and expand.

- **Phase 0 — The fork (now).** Fork Ubuntu's App Center. Three backends, one
  store: **snap + deb + Flatpak**, behind a plugin interface. Prove the
  architecture — and prove the reinvention: one card per app, operations you
  can cancel, trust you can see. This is the Brave move: small delta, clean
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
6. **Reinvent, don't wrap.** APIs are the starting line, not the finish line.
   Every feature must answer: did we rethink it, or just wire the API to a
   button? Wrappers don't ship.

## Non-Goals

- We do **not** replace `apt`/`dnf`/`pacman`/`nix`. We unify their UX.
- We do **not** build a proprietary store backend or take a cut of anything.
- We do **not** fight distros. We sit on top and make them all feel like one.
- We do **not** chase feature parity with upstream's every whim — the delta
  stays small and deliberate.

## The One-Line Pitch

**One store for all of \*nix — apps, not packages. Libre forever.**

---

*This is the sapna. Everything we build — every branch, every plugin, every
benchmark — must answer two questions: does this get us closer to one store
for all of \*nix — and did we reinvent it, or just wrap an API? If not, it
doesn't ship.*
