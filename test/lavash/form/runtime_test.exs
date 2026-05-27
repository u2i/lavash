defmodule Lavash.Form.RuntimeTest do
  @moduledoc """
  Regression coverage for the per-submit actor lookup.

  This was a silent footgun: the component submit op hardcoded
  `socket.assigns[:current_user]` as the actor, but Phoenix's
  `on_mount` injection that populates `:current_user` only fires
  on LiveViews — never on components. Any component using
  `submit :form` for an action that depended on the actor
  (e.g. `relate_actor(:user)` on Ash create) silently lost it,
  the form-submit's `Ash.create` returned `{:error, changeset}`,
  and the user saw "nothing happens."

  The runtime now uses `Lavash.Form.Runtime.resolve_actor/1`
  which also accepts an explicit `:actor` prop. These tests
  cover the lookup precedence directly.
  """

  use ExUnit.Case, async: true

  alias Lavash.Form.Runtime

  describe "resolve_actor/1" do
    test "prefers :actor over :current_user when both are set" do
      explicit = %{id: "explicit"}
      current = %{id: "current"}

      assert Runtime.resolve_actor(%{actor: explicit, current_user: current}) == explicit
    end

    test "falls back to :current_user when :actor is missing" do
      current = %{id: "current"}
      assert Runtime.resolve_actor(%{current_user: current}) == current
    end

    test "falls back to :current_user when :actor is nil" do
      current = %{id: "current"}
      assert Runtime.resolve_actor(%{actor: nil, current_user: current}) == current
    end

    test "returns nil when neither key is present" do
      assert Runtime.resolve_actor(%{}) == nil
    end

    test "returns nil when both are nil" do
      assert Runtime.resolve_actor(%{actor: nil, current_user: nil}) == nil
    end

    test "accepts a Phoenix.LiveView.Socket and reads from assigns" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user: %{id: "from-socket"}},
        private: %{}
      }

      assert Runtime.resolve_actor(socket) == %{id: "from-socket"}
    end

    test "Socket with :actor prop wins over :current_user (the bug case)" do
      # This is exactly the AddressEditModal scenario: the
      # component receives `:actor` as a prop, and may or may not
      # also have an inherited `:current_user`. The explicit prop
      # must win so component authors can override.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          actor: %{id: "from-prop"},
          current_user: %{id: "wrong"}
        },
        private: %{}
      }

      assert Runtime.resolve_actor(socket) == %{id: "from-prop"}
    end

    test "Socket with no actor and no current_user returns nil" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}},
        private: %{}
      }

      assert Runtime.resolve_actor(socket) == nil
    end

    test "ignores non-actor keys" do
      assert Runtime.resolve_actor(%{other_thing: %{id: "x"}}) == nil
    end

    test "non-map argument returns nil" do
      assert Runtime.resolve_actor(nil) == nil
      assert Runtime.resolve_actor("not a map") == nil
      assert Runtime.resolve_actor(:atom) == nil
    end
  end
end
