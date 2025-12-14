defmodule Lavash.Type do
  @moduledoc """
  Behaviour for bidirectional type conversion between URL strings and Elixir values.

  Lavash uses this for:
  - Parsing URL params into typed Elixir values
  - Serializing Elixir values back to URL-safe strings

  ## Built-in Types

  - `:string` - Pass-through, no conversion
  - `:integer` - `"42"` ↔ `42`
  - `:float` - `"3.14"` ↔ `3.14`
  - `:boolean` - `"true"/"false"` ↔ `true/false`
  - `:atom` - `"foo"` ↔ `:foo` (uses `String.to_existing_atom/1`)
  - `{:array, type}` - `"a,b,c"` ↔ `["a", "b", "c"]` (with inner type conversion)

  ## Custom Types

  Implement the `Lavash.Type` behaviour for custom types:

      defmodule MyApp.Types.Date do
        use Lavash.Type

        @impl true
        def parse(value) when is_binary(value) do
          case Date.from_iso8601(value) do
            {:ok, date} -> {:ok, date}
            {:error, _} -> {:error, "invalid date format"}
          end
        end

        @impl true
        def dump(%Date{} = date), do: Date.to_iso8601(date)
      end

  Then use in your state definition:

      field :start_date, MyApp.Types.Date, default: nil
  """

  @doc """
  Parses a URL string into a typed Elixir value.

  Returns `{:ok, value}` on success, `{:error, reason}` on failure.
  """
  @callback parse(String.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  Serializes an Elixir value to a URL-safe string.
  """
  @callback dump(term()) :: String.t()

  @optional_callbacks parse: 1, dump: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Lavash.Type
    end
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Parses a URL param string into the given type.

  ## Examples

      iex> Lavash.Type.parse(:integer, "42")
      {:ok, 42}

      iex> Lavash.Type.parse(:boolean, "true")
      {:ok, true}

      iex> Lavash.Type.parse({:array, :integer}, "1,2,3")
      {:ok, [1, 2, 3]}
  """
  def parse(type, value)

  def parse(_type, nil), do: {:ok, nil}

  def parse(:string, value) when is_binary(value), do: {:ok, value}

  def parse(:integer, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      {int, _rest} -> {:ok, int}
      :error -> {:error, "cannot parse #{inspect(value)} as integer"}
    end
  end

  def parse(:float, value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      {float, _rest} -> {:ok, float}
      :error -> {:error, "cannot parse #{inspect(value)} as float"}
    end
  end

  def parse(:boolean, "true"), do: {:ok, true}
  def parse(:boolean, "false"), do: {:ok, false}
  def parse(:boolean, "1"), do: {:ok, true}
  def parse(:boolean, "0"), do: {:ok, false}
  def parse(:boolean, value), do: {:error, "cannot parse #{inspect(value)} as boolean"}

  def parse(:atom, value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, "atom #{inspect(value)} does not exist"}
  end

  def parse({:array, inner_type}, value) when is_binary(value) do
    if value == "" do
      {:ok, []}
    else
      value
      |> String.split(",")
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
        case parse(inner_type, String.trim(item)) do
          {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    end
  end

  # Handle already-parsed list (e.g., from Phoenix params with foo[]=a&foo[]=b)
  def parse({:array, inner_type}, values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse(inner_type, item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  # Custom type module
  def parse(type, value) when is_atom(type) and is_binary(value) do
    if lavash_type?(type) do
      type.parse(value)
    else
      {:error, "unknown type #{inspect(type)}"}
    end
  end

  @doc """
  Parses a URL param string into the given type, raising on error.

  ## Examples

      iex> Lavash.Type.parse!(:integer, "42")
      42
  """
  def parse!(type, value) do
    case parse(type, value) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "parse error: #{reason}"
    end
  end

  @doc """
  Serializes a typed Elixir value to a URL-safe string.

  ## Examples

      iex> Lavash.Type.dump(:integer, 42)
      "42"

      iex> Lavash.Type.dump(:boolean, true)
      "true"

      iex> Lavash.Type.dump({:array, :integer}, [1, 2, 3])
      "1,2,3"
  """
  def dump(type, value)

  def dump(_type, nil), do: nil

  def dump(:string, value) when is_binary(value), do: value
  def dump(:integer, value) when is_integer(value), do: Integer.to_string(value)
  def dump(:float, value) when is_float(value), do: Float.to_string(value)
  def dump(:boolean, true), do: "true"
  def dump(:boolean, false), do: "false"
  def dump(:atom, value) when is_atom(value), do: Atom.to_string(value)

  def dump({:array, inner_type}, values) when is_list(values) do
    values
    |> Enum.map(&dump(inner_type, &1))
    |> Enum.join(",")
  end

  # Custom type module
  def dump(type, value) when is_atom(type) do
    if lavash_type?(type) do
      type.dump(value)
    else
      to_string(value)
    end
  end

  # Fallback - just use to_string
  def dump(_type, value), do: to_string(value)

  # ============================================================================
  # Helpers
  # ============================================================================

  defp lavash_type?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :parse, 1)
  end
end
