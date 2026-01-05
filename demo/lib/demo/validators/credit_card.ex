defmodule Demo.Validators.CreditCard do
  @moduledoc """
  Reusable reactive validation functions for credit card processing.

  These functions are defined with `defrx` and can be imported into any
  LiveView using `import_rx Demo.Validators.CreditCard`.

  All functions are expanded inline at each call site and transpiled to
  JavaScript for optimistic client-side validation.

  ## Available Functions

  - `valid_expiry?(digits)` - Validates MMYY format expiration date
  - `valid_cvv?(digits, is_amex)` - Validates CVV length (4 for Amex, 3 otherwise)
  - `valid_card_number?(digits, is_amex)` - Full card validation (digits, length, Luhn)

  ## Example

      defmodule MyAppWeb.PaymentLive do
        use Lavash.LiveView
        import Lavash.Rx
        import_rx Demo.Validators.CreditCard

        calculate :card_valid, rx(valid_card_number?(@digits, @is_amex))
      end
  """
  use Lavash.Rx.Functions

  # Validates expiration date format.
  # Expects a 4-digit string (MMYY format, digits only).
  # Returns true if length is 4 and month (first 2 digits) is 01-12.
  defrx valid_expiry?(digits) do
    String.length(digits) == 4 &&
      String.to_integer(String.slice(digits, 0, 2) || "0") >= 1 &&
      String.to_integer(String.slice(digits, 0, 2) || "0") <= 12
  end

  # Validates CVV length based on card type.
  # American Express cards require 4 digits, all others require 3.
  defrx valid_cvv?(digits, is_amex) do
    if(is_amex, do: String.length(digits) == 4, else: String.length(digits) == 3)
  end

  # Returns expected card number length for a card type.
  # American Express: 15 digits, all others: 16 digits
  defrx expected_card_length(is_amex) do
    if(is_amex, do: 15, else: 16)
  end

  # Calculates Luhn checksum sum from reversed digit list.
  # Takes a list of integers (card digits in reverse order) and returns
  # the Luhn sum. Doubles digits at odd indices and subtracts 9 if > 9.
  defrx luhn_sum(digits_reversed) do
    Enum.sum(
      Enum.map(
        Enum.with_index(digits_reversed),
        fn {digit, index} ->
          if(rem(index, 2) == 1,
            do: if(digit * 2 > 9, do: digit * 2 - 9, else: digit * 2),
            else: digit
          )
        end
      )
    )
  end

  # Converts a digit string to a reversed list of integers.
  # Used to prepare card number for Luhn checksum calculation.
  defrx digits_to_reversed_ints(digits) do
    Enum.reverse(Enum.map(String.graphemes(digits), fn d -> String.to_integer(d) end))
  end

  # Full card number validation.
  # Validates that:
  # 1. The string contains only digits
  # 2. Length matches expected for card type (15 for Amex, 16 for others)
  # 3. Passes Luhn checksum validation
  defrx valid_card_number?(digits, is_amex) do
    String.match?(digits, ~r/^\d+$/) &&
      String.length(digits) == expected_card_length(is_amex) &&
      rem(luhn_sum(digits_to_reversed_ints(digits)), 10) == 0
  end
end
