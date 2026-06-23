# Deferred ideas

Features and improvements intentionally **not** built yet, kept here so they aren't lost.
Nothing in this file is committed work — it's a parking lot.

---

## `mix workslot.clean` — drop orphaned worktree databases

**The problem.** `workslot` only ever *computes* database names; it never creates or
drops anything. So when you delete a git worktree (`git worktree remove ...`), its dev/test
databases keep sitting in Postgres forever. Over time you accumulate orphaned databases:
`my_app_dev_feature_x`, `my_app_dev_old_spike`, `my_app_test_abandoned_branch`, … none of which
map to a worktree that still exists.

**The idea.** A task that lists (and optionally drops) databases belonging to worktrees that are
gone:

```bash
mix workslot.clean            # dry run: list orphaned databases, drop nothing
mix workslot.clean --drop     # actually drop them, after an explicit confirmation
```

**Sketch of how it could work.**
- Ask git for the live worktrees: `git worktree list --porcelain` → set of current folder names
  → derive the set of DB suffixes that are still "alive."
- Ask Postgres for the actual databases matching the app's prefix
  (`my_app_dev_*` / `my_app_test_*`).
- The difference = orphans. Print them. With `--drop`, drop each one.

**Why it's deferred / what to be careful about.**
- This is the **first destructive thing** the library would do. Everything today is pure name
  derivation; dropping databases is a different risk class. It must:
  - default to a **dry run** (list only),
  - require an explicit `--drop` flag *and* a typed confirmation,
  - never touch the bare `my_app_dev` / `my_app_test` (the main checkout's databases),
  - probably support `--dry-run`/`--yes` for scripting.
- Detecting "which databases belong to this app" reliably means reading the configured DB prefix,
  not guessing — needs the same shape-reading logic `mix workslot` already uses.
- Connecting to Postgres to enumerate/drop databases pulls a DB driver into a library that
  currently has **zero runtime dependencies**. Worth keeping that property; maybe shell out to
  `psql`/`dropdb` instead of adding `postgrex`.

**Verdict:** genuinely useful, but it's a feature with real blast radius. Build it deliberately,
with safety rails, after the core correctness/test work lands.

---

## `mix workslot.doctor` — detect collisions and orphans (read-only)

**The problem.** The library derives readable database names from the worktree folder name
(`my_app_dev_feature_x`) and a port from the full filesystem path. Two situations are worth
surfacing but aren't prevented by the names themselves:

- **Collisions:** two *live* checkouts whose folder names sanitize to the same slug would map to
  the same database name (e.g. `/projects/feature-x` and `/archive/feature-x` both →
  `my_app_dev_feature_x`). Silent shared data if it happens.
- **Orphans:** databases left behind by worktrees that no longer exist (see `mix workslot.clean`).

**The idea.** A read-only diagnostic that answers "is my isolation actually clean?":

```bash
mix workslot.doctor
# ✓ 3 worktrees, 3 distinct databases, 3 distinct ports
# ⚠ collision: feature-x (/projects) and feature-x (/archive) both map to my_app_dev_feature_x
# ⚠ orphan: my_app_dev_old_spike has no matching worktree
```

**Why this beats encoding the info in the name.** We considered baking the port number into the
DB name (`my_app_dev_feature_x_4317`) to disambiguate and to "list duplicates." Rejected because
it reintroduces move-loses-data, couples the DB name to the `PORT` env var, and doesn't fit test
databases (which have no port). A read-only tool gives the same insight — *and explains it* —
without making every name uglier, longer, and move-fragile.

**Sketch.**
- Enumerate live checkouts (`git worktree list --porcelain`, plus the current checkout).
- Compute each one's expected dev/test DB names and dev port (reuse `mix workslot`'s shape-reading).
- Query Postgres for the actual `<app>_dev_*` / `<app>_test_*` databases.
- Report: collisions (two live checkouts → one name), orphans (DB with no live checkout), and a
  clean ✓ when everything is distinct.

**Relationship to `mix workslot.clean`:** `doctor` is the read-only diagnosis; `clean` is the
destructive follow-up that drops orphans. `doctor` ships first and stays safe (no writes ever).

---

## Database ownership stamp — opt-in collision detection across deletions

**The problem this adds over the boot guard.** The shipped boot guard (`Workslot.verify!/0`)
catches *live* folder-name collisions by listing current worktrees from git. It cannot catch
**orphan adoption**: you delete worktree `feature-x`, its database lingers in Postgres, then later
you create a *new* `feature-x` elsewhere — git no longer knows about the old one, so the new
checkout silently adopts the leftover data.

**The idea.** Stamp each database with the full path of the checkout that owns it, and verify it on
boot. Postgres lets you attach a comment to the database object itself:

```sql
COMMENT ON DATABASE my_app_dev_feature_x IS 'workslot:/Users/you/projects/feature-x';
```

- Written once, when the database is created (or first migrated).
- On boot, `verify!/0` reads the comment; if it names a path other than the current checkout's,
  it **fails loudly** — even though the colliding worktree no longer exists.
- Stored on the database object, so it survives `ecto.migrate` and schema changes (it is not a
  table inside the schema).

**Why it's opt-in / deferred, not default.** The library today only *derives names* — it never
touches a database. Stamping means the library starts **writing** database metadata, which is a
real change in what it is. It also needs a deliberate hook (post-`ecto.create` / first migrate),
and care that `ecto.reset` / `ecto.drop`+recreate re-stamps correctly rather than leaving a stale
or missing comment.

**Verdict:** valuable hardening for heavy worktree churn, but it changes the library's character
from "pure name derivation" to "manages database metadata." Ship it behind an explicit opt-in
(e.g. a config flag), after the pure boot guard has proven the collision-detection UX.
