# Deferred ideas

Features and improvements intentionally **not** built yet, kept here so they aren't lost.
Nothing in this file is committed work — it's a parking lot.

---

## `mix workslot.doctor` — detect collisions and orphans (read-only)

**The problem.** The library derives readable database names from the worktree folder name
(`my_app_dev_feature_x`) and a port from the full filesystem path. Two situations are worth
surfacing but aren't prevented by the names themselves:

- **Collisions:** two *live* checkouts whose folder names sanitize to the same slug would map to
  the same database name (e.g. `/projects/feature-x` and `/archive/feature-x` both →
  `my_app_dev_feature_x`). Silent shared data if it happens.
- **Orphans:** databases left behind by worktrees that no longer exist — `mix workslot.clean` (shipped in
  0.2.0) already lists these; `doctor` would fold them into one report.

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

**Relationship to `mix workslot.clean`:** `clean` (shipped) already finds and drops orphans; `doctor`
would add the collision half and stay strictly read-only.

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

**Since 0.2.0 — what the stamp would still add over the suffix registry.** `mix workslot.clean` decides
ownership from the record `config/worktree.exs` keeps under `.git/workslot/`, which is per clone. Two
clones of one app on one Postgres server that each have a worktree with the same folder name already
share that database (the name carries no clone), and when one clone removes its worktree, `clean` there
reports the shared database as its orphan; only an open connection stops the drop. A stamp naming the
owning clone's git directory would let `clean` refuse a candidate stamped by another clone. Un-defer
when anyone runs several clones of one app against one server.
