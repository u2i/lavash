defmodule Lavash.Test.Magic.Regions do
  @moduledoc """
  defrx fixture: country-dependent region options, expanded inline and
  transpiled at each rx() call site (see DependentSelectLive).
  """
  use Lavash.Rx.Functions

  defrx region_opts(country) do
    if country == "CA" do
      [%{name: "Ontario", code: "ON"}, %{name: "Quebec", code: "QC"}]
    else
      [%{name: "California", code: "CA"}, %{name: "Texas", code: "TX"}]
    end
  end
end

defmodule Lavash.Test.Magic.DependentSelect do
  @moduledoc "Test Ash domain for the dependent-select integration tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Lavash.Test.Magic.DependentSelect.Shipping)
  end
end

defmodule Lavash.Test.Magic.DependentSelect.Shipping do
  @moduledoc "Minimal resource backing the dependent-select form fixture."
  use Ash.Resource,
    domain: Lavash.Test.Magic.DependentSelect,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :country, :string do
      public?(true)
    end

    attribute :state, :string do
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:country, :state])
    end
  end
end

defmodule Lavash.Test.Magic.DependentSelectLive do
  @moduledoc """
  Fixture for dependent-select e2e tests: one country select drives two
  region selects fed by the same form params.

  - `#fast-region` — options come from an OPTIMISTIC calc chain
    (defrx-expanded, transpiled). The `:for` over `@fast_options` is
    auto-extracted as a subtree derive, so changing the country
    re-renders the options client-side in the same task as the change
    event — no server involvement.

  - `#slow-region` — options come from the same chain marked
    `optimistic: false`. No client-side derive exists, so the options
    only change when the server re-renders after the round-trip.
  """
  use Lavash.LiveView

  import_rx(Lavash.Test.Magic.Regions)

  # Explicitly optimistic so the LiveView renders the LavashOptimistic
  # hook wrapper and the params live in client state (same pattern as
  # FormValidationDemoLive).
  state :addr_params, :map, from: :ephemeral, default: %{}, optimistic: true

  form :addr, Lavash.Test.Magic.DependentSelect.Shipping do
    create :create
  end

  # Optimistic chain: swaps client-side the moment the country changes.
  calculate :fast_country, rx(@addr_params["country"] || "US")
  calculate :fast_options, rx(region_opts(@fast_country))

  # Server-only chain: same inputs, swap arrives with the server render.
  calculate :slow_country, rx(@addr_params["country"] || "US"), optimistic: false
  calculate :slow_options, rx(region_opts(@slow_country)), optimistic: false

  template do
    ~H"""
    <div>
      <form id="dep-form" phx-change="validate_addr">
        <select id="country" name="addr[country]" data-lavash-bind="addr_params.country">
          <option value="US" selected>US</option>
          <option value="CA">CA</option>
        </select>

        <select id="fast-region" name="addr[state]" data-lavash-bind="addr_params.state">
          <option :for={opt <- @fast_options} value={opt.code}>{opt.name}</option>
        </select>

        <select id="slow-region">
          <option :for={opt <- @slow_options} value={opt.code}>{opt.name}</option>
        </select>
      </form>
    </div>
    """
  end
end
