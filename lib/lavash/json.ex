defmodule Lavash.JSON do
  @moduledoc """
  JSON encoding utilities for Lavash optimistic state.

  Handles encoding of Elixir-specific types that Jason doesn't support natively:
  - Tuples are encoded as arrays (e.g., `{:edit, "uuid"}` → `["edit", "uuid"]`)
  - Atoms are encoded as strings (already supported by Jason)
  - All other types pass through to Jason

  This allows idiomatic Elixir tagged unions like:
      nil | :create | {:edit, id}

  To be serialized for JavaScript as:
      null | "create" | ["edit", "uuid"]
  """

  @doc """
  Encodes a value to JSON, converting tuples to arrays.

  ## Examples

      iex> Lavash.JSON.encode!(:create)
      "\"create\""

      iex> Lavash.JSON.encode!({:edit, "uuid-123"})
      "[\"edit\",\"uuid-123\"]"

      iex> Lavash.JSON.encode!(nil)
      "null"
  """
  def encode!(value) do
    value
    |> prepare_for_json()
    |> Jason.encode!()
  end

  @doc """
  Prepares a value for JSON encoding by converting tuples to lists recursively.
  """
  def prepare_for_json(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&prepare_for_json/1)
  end

  def prepare_for_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, prepare_for_json(v)} end)
  end

  def prepare_for_json(value) when is_list(value) do
    Enum.map(value, &prepare_for_json/1)
  end

  def prepare_for_json(value), do: value

  @doc """
  Decodes JSON and converts arrays back to tuples where appropriate.

  Arrays that look like tagged tuples (first element is a string that looks like
  an atom) are converted back to tuples.

  ## Examples

      iex> Lavash.JSON.decode!("\"create\"")
      :create

      iex> Lavash.JSON.decode!("[\"edit\",\"uuid-123\"]")
      {:edit, "uuid-123"}
  """
  def decode!(json) do
    json
    |> Jason.decode!()
    |> restore_from_json()
  end

  @doc """
  Restores Elixir types from JSON-decoded values.

  - Strings that look like atoms (lowercase, underscores) become atoms
  - Arrays that look like tagged tuples become tuples
  """
  def restore_from_json(value) when is_list(value) do
    case value do
      [tag | rest] when is_binary(tag) ->
        if atom_like?(tag) do
          # Looks like a tagged tuple
          List.to_tuple([String.to_existing_atom(tag) | Enum.map(rest, &restore_from_json/1)])
        else
          Enum.map(value, &restore_from_json/1)
        end

      _ ->
        Enum.map(value, &restore_from_json/1)
    end
  end

  def restore_from_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, restore_from_json(v)} end)
  end

  def restore_from_json(value) when is_binary(value) do
    if atom_like?(value) do
      try do
        String.to_existing_atom(value)
      rescue
        ArgumentError -> value
      end
    else
      value
    end
  end

  def restore_from_json(value), do: value

  # Check if a string looks like an Elixir atom (lowercase letters, underscores, digits)
  defp atom_like?(s) when is_binary(s) do
    String.match?(s, ~r/^[a-z][a-z0-9_]*$/)
  end
end
