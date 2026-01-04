defmodule Lavash.String do
  @moduledoc """
  String utility functions that transpile to JavaScript.

  These functions extend Elixir's String module with operations that have
  clean JavaScript equivalents, making them suitable for use in `rx()` expressions.

  ## Usage

  Import this module in your LiveView to use these functions in calculations:

      import Lavash.String

      calculate :card_number_formatted,
        rx(String.chunk(@card_number_digits, 4) |> Enum.join(" "))

  ## Available Functions

  - `chunk/2` - Split a string into chunks of a given size
  """

  @doc """
  Splits a string into chunks of the given size.

  Returns a list of strings, each at most `size` characters long.
  The last chunk may be shorter if the string length isn't evenly divisible.

  ## Examples

      iex> Lavash.String.chunk("12345678", 4)
      ["1234", "5678"]

      iex> Lavash.String.chunk("123456789", 4)
      ["1234", "5678", "9"]

      iex> Lavash.String.chunk("", 4)
      []

  ## JavaScript Equivalent

  This transpiles to:
      str.match(/.{1,4}/g) || []
  """
  @spec chunk(String.t(), pos_integer()) :: [String.t()]
  def chunk(string, size) when is_binary(string) and is_integer(size) and size > 0 do
    if string == "" do
      []
    else
      string
      |> String.graphemes()
      |> Enum.chunk_every(size)
      |> Enum.map(&Enum.join/1)
    end
  end
end
