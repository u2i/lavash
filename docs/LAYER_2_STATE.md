# Layer 2: State management

Declarative persistence and sync. `state :foo, :type, from: ...` declares
where a piece of state comes from and where its mutations propagate to.
Server is always authoritative; the client carries a flat `lavashState`
object across reconnects.

## State

Lavash supports several persistence sources:

| `from:` | Persisted in | Survives refresh | Survives reconnect | Shareable |
|---|---|---|---|---|
| `:url` | Query string | Yes | Yes | Yes |
| `:socket` | JS client | No | Yes | No |
| `:session` | Phoenix session | Yes | Yes | No |
| `:assigns` | Existing assign | depends on source | depends on source | depends on source |
| `:ephemeral` (default) | Process only | No | No | No |

```elixir
# URL-backed: filters, pagination, tabs
state :search, :string, from: :url, default: ""
state :page, :integer, from: :url, default: 1

# Socket-backed: UI state that survives reconnects
state :expanded_ids, {:array, :uuid}, from: :socket, default: []

# Lift an on_mount-injected assign (e.g. @current_user from your auth
# plug) into lavash state so calculate/actions can see it.
state :user, :map, from: :assigns, assigns_key: :current_user

# Ephemeral: temporary
state :hovering, :boolean, default: false
```

`from: :url` looks up the query/path parameter under the field name by
default. If the URL key needs to differ — typically because the query
string uses a shorter name — set `url_name:`:

```elixir
# URL: /attest?subject=alice
state :subject_handle, :string, from: :url, default: nil, url_name: "subject"
```

When a `from: :url` field falls back to its default and there's no
matching key in the params (and the URL did have other params), Lavash
logs a dev-only warning so a mismatched `url_name` doesn't silently
hydrate to `nil`. Use `required: true` if missing the param should
raise instead.

## Auto-generated setters

`setter: true` generates a `set_<name>` action callable from the client (e.g.
from a form input's `phx-change`):

```elixir
state :search, :string, from: :url, default: "", setter: true
# Generates: action :set_search, [:value] do set :search, rx(@value) end
```

## Type system

Built-in types with automatic URL serialization:

- `:string` — pass-through
- `:integer` — `"42"` ↔ `42`
- `:float` — `"3.14"` ↔ `3.14`
- `:boolean` — `"true"` ↔ `true`
- `:uuid` — full UUID ↔ base32 (26 chars)
- `{:uuid, "prefix"}` — TypeID format (`cat_01h455vb4pex5vsknk084sn02q`)
- `:atom` — uses `String.to_existing_atom/1`
- `{:array, type}` — `"a,b,c"` ↔ `["a", "b", "c"]`

### Custom types

```elixir
defmodule MyApp.Types.Date do
  use Lavash.Type

  @impl true
  def parse(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid date"}
    end
  end

  @impl true
  def dump(%Date{} = date), do: Date.to_iso8601(date)
end

state :start_date, MyApp.Types.Date, from: :url
```
