defmodule Lavash.AssignsTest do
  @moduledoc """
  Coverage for `Lavash.Assigns.project/2`'s form metadata pass.

  Specifically the regression where a form loaded via
  `async_assign` is wrapped in an `%AsyncResult{}` on the socket,
  but `project_form_metadata` only knew how to unwrap a raw
  `%Lavash.Form{}`. The fallthrough was `nil`, which made
  `@my_form_action == :create` always false in templates and
  silently inverted "Add" vs "Edit" labels.
  """

  use ExUnit.Case, async: true

  alias Lavash.Assigns
  alias Lavash.Form, as: LForm

  defp bare_socket(extra_assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, extra_assigns),
      private: %{}
    }
  end

  defmodule FormHostModule do
    def __lavash__(:forms) do
      [%{name: :address_form, resource: :stub}]
    end

    def __lavash__(:states), do: []
    def __lavash__(_), do: []
  end

  defmodule NoFormsModule do
    def __lavash__(:forms), do: []
    def __lavash__(:states), do: []
    def __lavash__(_), do: []
  end

  describe "project/2 — form_action metadata" do
    test "projects :create for a raw create-shape Lavash.Form" do
      form = %LForm{
        changeset: nil,
        form: nil,
        action_type: :create,
        name: "address"
      }

      socket = bare_socket(%{address_form: form})

      projected = Assigns.project(socket, FormHostModule)

      assert projected.assigns.address_form_action == :create
    end

    test "projects :update for a raw update-shape Lavash.Form" do
      form = %LForm{
        changeset: nil,
        form: nil,
        action_type: :update,
        name: "address"
      }

      socket = bare_socket(%{address_form: form})

      projected = Assigns.project(socket, FormHostModule)

      assert projected.assigns.address_form_action == :update
    end

    test "unwraps an AsyncResult{ok?: true} containing a Lavash.Form" do
      # Regression: `async_assign :address_form` wraps the resolved
      # form in `%AsyncResult{}`. Before the fix, the projection
      # fell through to nil and templates rendered "Edit" /
      # "Update" labels when the user intended "Add" / "Save".
      form = %LForm{
        changeset: nil,
        form: nil,
        action_type: :create,
        name: "address"
      }

      async = %Phoenix.LiveView.AsyncResult{
        ok?: true,
        loading: nil,
        failed: nil,
        result: form
      }

      socket = bare_socket(%{address_form: async})

      projected = Assigns.project(socket, FormHostModule)

      assert projected.assigns.address_form_action == :create
    end

    test "unwraps an AsyncResult containing an :update form" do
      form = %LForm{
        changeset: nil,
        form: nil,
        action_type: :update,
        name: "address"
      }

      async = %Phoenix.LiveView.AsyncResult{
        ok?: true,
        loading: nil,
        failed: nil,
        result: form
      }

      socket = bare_socket(%{address_form: async})

      projected = Assigns.project(socket, FormHostModule)

      assert projected.assigns.address_form_action == :update
    end

    test "projects :loading for an in-flight AsyncResult" do
      async = %Phoenix.LiveView.AsyncResult{
        ok?: false,
        loading: [:address_form],
        failed: nil,
        result: nil
      }

      socket = bare_socket(%{address_form: async})

      projected = Assigns.project(socket, FormHostModule)

      assert projected.assigns.address_form_action == :loading
    end

    test "projects {:error, _} for a failed AsyncResult" do
      async = %Phoenix.LiveView.AsyncResult{
        ok?: false,
        loading: nil,
        failed: :boom,
        result: nil
      }

      socket = bare_socket(%{address_form: async})

      projected = Assigns.project(socket, FormHostModule)

      assert projected.assigns.address_form_action == {:error, :boom}
    end

    test "projects nil when the form assign is missing entirely" do
      socket = bare_socket()

      projected = Assigns.project(socket, FormHostModule)

      assert projected.assigns.address_form_action == nil
    end

    test "no-op for modules that declare no forms" do
      socket = bare_socket(%{some_field: "untouched"})

      projected = Assigns.project(socket, NoFormsModule)

      # The form-projection assign was never added.
      refute Map.has_key?(projected.assigns, :address_form_action)
      # And other assigns are untouched.
      assert projected.assigns.some_field == "untouched"
    end
  end
end
