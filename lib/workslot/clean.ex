defmodule Workslot.Clean do
  @moduledoc """
  Pure planning behind `mix workslot.clean`: given the app's database bases (one per Repo and kind),
  the records of which suffixes each checkout derived (`Workslot.Registry`), and the databases that
  exist on each server, decide what removed worktrees left behind.

  Kept free of any database, git or file access so the decision — the part that must never drop the
  wrong thing — is unit-testable on its own. Names are never parsed for ownership: a database belongs
  to a checkout only because that checkout recorded deriving its name.

  A record *derives* a database when, on that base's server, the database is named `base <> suffix`
  for a base of one kind and a suffix recorded for that kind (dev suffixes with dev bases, test suffixes
  with test bases), cut at Postgres's 63-byte identifier limit. A removed worktree's record *claims* a
  database it derives only through a base its record is marked for (`Workslot.Registry`: a base clean
  had already seen when the worktree recorded, or while clean found it live — so an old record never
  claims a database under a base configured after its worktree was gone), and never one that was
  already there when clean first saw the base (its `preexisting` names: everything that existed before
  clean watched — a main checkout's old partition copy, a live worktree's databases of the time). Every
  existing database that starts with a base falls in one group:

    * **live** — a base itself, or a name some live record gives any base with any of its suffixes
      (deliberately broader than deriving). Never reported.
    * `:held` — likewise named by a worktree git still registers though its folder is gone.
    * `:orphan` — claimed by a removed worktree's record.
    * `:unregistered` — shaped like this app's worktree database (`<base>_…`) yet derived by no record:
      an older workslot's orphan, a hand-made copy, another clone's worktree.

  Anything else (a main checkout's partition copy under an older `config/worktree.exs`, another app
  sharing the prefix without the `_`) is left out. A database several bases match takes the most
  specific group (orphan, then held, then unregistered), then the longest base, so overlapping bases
  (`foo`, `foo_test`) never file one kind's database under the other.

  A backstop keeps a worktree's databases live even before its config ever recorded them (a copy of
  `config/worktree.exs` from before recording, a worktree just added): given the folder slugs of the
  worktrees git lists (`:live_slugs`), a name workslot's default derivation gives one of them —
  `<dev base>_<slug>`, or `<test base>_<slug>` with an optional numeric partition — is not an orphan
  or unregistered. It can only keep more, never drop more; a held database stays reported as held.
  """

  alias Workslot.Registry

  @type kind :: :dev | :test
  # `key` names the base (kind, name, destination); `preexisting` is what was there when clean first saw
  # it (`Workslot.Registry`) — nil for a base clean has not seen yet, which claims nothing.
  @type base :: %{
          required(:kind) => kind(),
          required(:name) => String.t(),
          required(:server) => term(),
          optional(:key) => String.t(),
          optional(:preexisting) => MapSet.t(String.t()) | nil
        }
  @type group :: :orphan | :held | :unregistered
  @type db :: %{
          name: String.t(),
          server: term(),
          kind: kind(),
          group: group(),
          worktree: String.t() | nil,
          size: non_neg_integer(),
          conns: non_neg_integer()
        }
  @type existing :: %{term() => %{String.t() => {non_neg_integer(), non_neg_integer()}}}

  # Postgres truncates identifiers to NAMEDATALEN - 1 = 63 bytes.
  @max_identifier 63

  @doc """
  Every reportable database, sorted by group then name. `bases` must hold every Repo's bases of both
  kinds — they all decide what is live.

  Options: `:kinds` restricts what is reported (default both); `:live_slugs` are the folder slugs of
  the worktrees git lists (default none).
  """
  @spec plan([base()], [Registry.entry()], existing(), keyword()) :: [db()]
  def plan(bases, records, existing, opts \\ []) do
    kinds = Keyword.get(opts, :kinds, [:dev, :test])
    slugs = Keyword.get(opts, :live_slugs, [])
    by_state = Enum.group_by(records, & &1.state)
    live = live_names(bases, records)
    held = named(bases, by_state[:held])
    gone = Map.get(by_state, :gone, [])

    for base <- bases,
        {name, {size, conns}} <- Map.get(existing, base.server, %{}),
        String.starts_with?(name, base.name),
        not MapSet.member?(live, name),
        {group, worktree} = group(name, base, held, gone, by_state[:held]),
        group != nil,
        group == :held or not slug_live?(name, bases, slugs) do
      %{
        name: name,
        server: base.server,
        kind: base.kind,
        base: base.name,
        group: group,
        worktree: worktree,
        size: size,
        conns: conns
      }
    end
    # the most specific group, then the longest base, wins: `foo_test_x` is `foo_test`'s, not `foo`'s
    |> Enum.sort_by(&{order(&1.group), -byte_size(&1.base)})
    |> Enum.uniq_by(&{&1.server, &1.name})
    |> Enum.map(&Map.delete(&1, :base))
    |> Enum.filter(&(&1.kind in kinds))
    |> Enum.sort_by(&{order(&1.group), &1.name})
  end

  @doc "The names no group may hold: every base itself, and what live records give any base."
  @spec live_names([base()], [Registry.entry()]) :: MapSet.t(String.t())
  def live_names(bases, records) do
    live = Enum.filter(records, &(&1.state == :live))
    bases |> MapSet.new(&cut(&1.name)) |> MapSet.union(named(bases, live))
  end

  @doc """
  Every `{server, name}` a record names with any base — for retiring a record once none of them exist
  (broad on purpose: a record is kept while anything it might name is still there).
  """
  @spec derived_names([base()], Registry.entry()) :: [{term(), String.t()}]
  def derived_names(bases, record) do
    for base <- bases,
        suffix <- record.suffixes ++ record.test_suffixes,
        uniq: true,
        do: {base.server, cut(base.name <> suffix)}
  end

  defp group(name, base, held, gone, held_records) do
    cond do
      MapSet.member?(held, name) -> {:held, held_records |> deriving(base, name) |> label()}
      record = claiming(gone, base, name) -> {:orphan, label(record)}
      String.starts_with?(name, base.name <> "_") -> {:unregistered, nil}
      true -> {nil, nil}
    end
  end

  # The first record that derives `name` from `base`: same kind, cut like Postgres stores it.
  defp deriving(records, base, name) do
    Enum.find(records || [], fn record ->
      record |> kind_suffixes(base.kind) |> Enum.any?(&(cut(base.name <> &1) == name))
    end)
  end

  defp claiming(records, base, name) do
    preexisting = Map.get(base, :preexisting)

    if preexisting && not MapSet.member?(preexisting, name),
      do: records |> Enum.filter(&MapSet.member?(&1.bases, base.key)) |> deriving(base, name)
  end

  defp kind_suffixes(record, :dev), do: record.suffixes
  defp kind_suffixes(record, :test), do: record.test_suffixes

  # Every name the records give any base with any of their suffixes.
  defp named(bases, records) do
    for record <- records || [],
        base <- bases,
        suffix <- record.suffixes ++ record.test_suffixes,
        into: MapSet.new(),
        do: cut(base.name <> suffix)
  end

  defp slug_live?(name, bases, slugs) do
    Enum.any?(bases, fn base ->
      Enum.any?(slugs, fn slug ->
        derived = cut(base.name <> "_" <> slug)

        name == derived or
          (base.kind == :test and String.starts_with?(name, derived) and
             name |> String.replace_prefix(derived, "") |> String.match?(~r/\A\d+\z/))
      end)
    end)
  end

  defp label(nil), do: nil
  defp label(%{path: path}) when is_binary(path), do: Path.basename(path)
  defp label(%{id: id}), do: to_string(id)

  defp cut(name) when byte_size(name) > @max_identifier, do: binary_part(name, 0, @max_identifier)
  defp cut(name), do: name

  defp order(:orphan), do: 0
  defp order(:held), do: 1
  defp order(:unregistered), do: 2
end
