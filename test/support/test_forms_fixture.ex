defmodule Lavash.TestForms do
  @moduledoc "Test Ash domain for the forms integration tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Lavash.TestForms.Signup)
  end
end

defmodule Lavash.TestForms.Signup do
  @moduledoc """
  Test fixture resource exercising the form DSL: required attributes with
  length / numeric constraints. Backed by a non-persistent ETS table so the
  test suite doesn't need a database.
  """
  use Ash.Resource,
    domain: Lavash.TestForms,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 2)
    end

    attribute :age, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 18)
    end
  end

  actions do
    defaults([:read])

    create :signup do
      accept([:name, :age])
    end
  end
end

defmodule Lavash.TestFormLive do
  @moduledoc """
  Fixture for forms tests. Uses ~H (not ~L) and explicit phx-change/phx-submit
  binding so the test runs without the LavashOptimistic JS hook.
  """
  use Lavash.LiveView

  state :signup_params, :map, from: :ephemeral, default: %{}
  state :submitted, :boolean, from: :ephemeral, default: false

  form :signup, Lavash.TestForms.Signup do
    create :signup
  end

  actions do
    action :save do
      submit :signup, on_success: :on_saved
    end

    action :on_saved do
      set :submitted, true
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <form id="signup-form" phx-change="form_change_signup" phx-submit="save">
        <input
          type="text"
          name="signup[name]"
          id="signup-name"
          value={Map.get(@signup_params, "name", "")}
        />
        <input
          type="text"
          name="signup[age]"
          id="signup-age"
          value={Map.get(@signup_params, "age", "")}
        />
        <span id="signup-name-errors">{Enum.join(@signup_name_errors || [], ", ")}</span>
        <span id="signup-age-errors">{Enum.join(@signup_age_errors || [], ", ")}</span>
        <span id="signup-valid">{to_string(@signup_valid)}</span>
        <button type="submit" id="signup-submit">Submit</button>
      </form>
      <span id="submitted">{to_string(@submitted)}</span>
    </div>
    """
  end
end
