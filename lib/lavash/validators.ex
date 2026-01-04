defmodule Lavash.Validators do
  @moduledoc """
  Validation functions that work both server-side (Elixir) and client-side (transpiled to JS).

  These are designed for use in `rx()` expressions within `calculate` declarations.
  """

  @doc """
  Validates a credit card number.

  Checks:
  1. Card type detection from prefix (Visa, Mastercard, Amex, Discover)
  2. Correct length for the detected card type
  3. Luhn checksum validation

  ## Examples

      iex> Lavash.Validators.valid_card_number?("4242424242424242")
      true

      iex> Lavash.Validators.valid_card_number?("4242424242424241")
      false  # fails Luhn

      iex> Lavash.Validators.valid_card_number?("424242424242424")
      false  # wrong length for Visa

      iex> Lavash.Validators.valid_card_number?("378282246310005")
      true   # valid Amex

      iex> Lavash.Validators.valid_card_number?("3782822463100050")
      false  # wrong length for Amex
  """
  @spec valid_card_number?(String.t()) :: boolean()
  def valid_card_number?(digits) when is_binary(digits) do
    # Must be all digits
    if not Regex.match?(~r/^\d+$/, digits) do
      false
    else
      card_type = detect_card_type(digits)
      expected_length = card_length(card_type)

      String.length(digits) == expected_length and luhn?(digits)
    end
  end

  def valid_card_number?(_), do: false

  @doc """
  Detects card type from the card number prefix.

  Returns one of: :visa, :mastercard, :amex, :discover, :unknown
  """
  @spec detect_card_type(String.t()) :: :visa | :mastercard | :amex | :discover | :unknown
  def detect_card_type(digits) when is_binary(digits) do
    cond do
      String.starts_with?(digits, "4") -> :visa
      String.starts_with?(digits, "5") -> :mastercard
      String.starts_with?(digits, "34") or String.starts_with?(digits, "37") -> :amex
      String.starts_with?(digits, "6011") -> :discover
      true -> :unknown
    end
  end

  def detect_card_type(_), do: :unknown

  @doc """
  Returns the expected card number length for a card type.
  """
  @spec card_length(:visa | :mastercard | :amex | :discover | :unknown) :: integer()
  def card_length(:amex), do: 15
  def card_length(:visa), do: 16
  def card_length(:mastercard), do: 16
  def card_length(:discover), do: 16
  def card_length(:unknown), do: 16

  @doc """
  Validates a card number using the Luhn algorithm (mod 10 checksum).

  ## Examples

      iex> Lavash.Validators.luhn?("4242424242424242")
      true

      iex> Lavash.Validators.luhn?("4242424242424241")
      false
  """
  @spec luhn?(String.t()) :: boolean()
  def luhn?(digits) when is_binary(digits) do
    if not Regex.match?(~r/^\d+$/, digits) do
      false
    else
      digits
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {digit, index} ->
        if rem(index, 2) == 1 do
          doubled = digit * 2
          if doubled > 9, do: doubled - 9, else: doubled
        else
          digit
        end
      end)
      |> Enum.sum()
      |> rem(10) == 0
    end
  end

  def luhn?(_), do: false
end
