defmodule DemoWeb.AddressRegions do
  @moduledoc """
  Country-dependent region (state/province) options for address forms.

  The address modals offer United States and Canada as countries; the
  region select and its label derive from the currently selected
  country — optimistically. `region_options/1` and `region_label/1`
  are `defrx` functions: their bodies are expanded inline at each
  `rx(...)` call site and transpiled to JavaScript, so changing the
  country swaps the option list client-side without waiting for the
  server round-trip.

  Import into a component with `import_rx DemoWeb.AddressRegions`.

  The first entry of each option list is the "Select..." prompt
  (empty code), so the whole `<option>` set — prompt included — can be
  re-rendered as one subtree derive.
  """
  use Lavash.Rx.Functions

  defrx region_options(country) do
    if country == "Canada" do
      [
        %{name: "Select...", code: ""},
        %{name: "Alberta", code: "AB"},
        %{name: "British Columbia", code: "BC"},
        %{name: "Manitoba", code: "MB"},
        %{name: "New Brunswick", code: "NB"},
        %{name: "Newfoundland and Labrador", code: "NL"},
        %{name: "Northwest Territories", code: "NT"},
        %{name: "Nova Scotia", code: "NS"},
        %{name: "Nunavut", code: "NU"},
        %{name: "Ontario", code: "ON"},
        %{name: "Prince Edward Island", code: "PE"},
        %{name: "Quebec", code: "QC"},
        %{name: "Saskatchewan", code: "SK"},
        %{name: "Yukon", code: "YT"}
      ]
    else
      [
        %{name: "Select...", code: ""},
        %{name: "Alabama", code: "AL"},
        %{name: "Alaska", code: "AK"},
        %{name: "Arizona", code: "AZ"},
        %{name: "Arkansas", code: "AR"},
        %{name: "California", code: "CA"},
        %{name: "Colorado", code: "CO"},
        %{name: "Connecticut", code: "CT"},
        %{name: "Delaware", code: "DE"},
        %{name: "Florida", code: "FL"},
        %{name: "Georgia", code: "GA"},
        %{name: "Hawaii", code: "HI"},
        %{name: "Idaho", code: "ID"},
        %{name: "Illinois", code: "IL"},
        %{name: "Indiana", code: "IN"},
        %{name: "Iowa", code: "IA"},
        %{name: "Kansas", code: "KS"},
        %{name: "Kentucky", code: "KY"},
        %{name: "Louisiana", code: "LA"},
        %{name: "Maine", code: "ME"},
        %{name: "Maryland", code: "MD"},
        %{name: "Massachusetts", code: "MA"},
        %{name: "Michigan", code: "MI"},
        %{name: "Minnesota", code: "MN"},
        %{name: "Mississippi", code: "MS"},
        %{name: "Missouri", code: "MO"},
        %{name: "Montana", code: "MT"},
        %{name: "Nebraska", code: "NE"},
        %{name: "Nevada", code: "NV"},
        %{name: "New Hampshire", code: "NH"},
        %{name: "New Jersey", code: "NJ"},
        %{name: "New Mexico", code: "NM"},
        %{name: "New York", code: "NY"},
        %{name: "North Carolina", code: "NC"},
        %{name: "North Dakota", code: "ND"},
        %{name: "Ohio", code: "OH"},
        %{name: "Oklahoma", code: "OK"},
        %{name: "Oregon", code: "OR"},
        %{name: "Pennsylvania", code: "PA"},
        %{name: "Rhode Island", code: "RI"},
        %{name: "South Carolina", code: "SC"},
        %{name: "South Dakota", code: "SD"},
        %{name: "Tennessee", code: "TN"},
        %{name: "Texas", code: "TX"},
        %{name: "Utah", code: "UT"},
        %{name: "Vermont", code: "VT"},
        %{name: "Virginia", code: "VA"},
        %{name: "Washington", code: "WA"},
        %{name: "West Virginia", code: "WV"},
        %{name: "Wisconsin", code: "WI"},
        %{name: "Wyoming", code: "WY"}
      ]
    end
  end

  defrx region_label(country) do
    if country == "Canada", do: "Province", else: "State"
  end

  @doc """
  Convert region option maps to `{label, value}` tuples for the
  `<.select>` component (drops the prompt entry — the component renders
  its own `prompt`).
  """
  def as_tuples(options) do
    for %{name: name, code: code} <- options, code != "", do: {name, code}
  end

  # ── Server-only helpers (record fallback for the edit flow) ──
  # The loaded address arrives as nil, a raw record, or an
  # %AsyncResult{}; extract fields safely. Used from
  # `optimistic: false` calcs — the record isn't available in client
  # state, so the client-side chain falls through `||` to its default.

  def address_country(%Phoenix.LiveView.AsyncResult{ok?: true, result: %{country: country}}),
    do: country

  def address_country(%{country: country}) when is_binary(country), do: country
  def address_country(_), do: nil

  def address_state(%Phoenix.LiveView.AsyncResult{ok?: true, result: %{state: state}}),
    do: state

  def address_state(%{state: state}) when is_binary(state), do: state
  def address_state(_), do: nil
end
