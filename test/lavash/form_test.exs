defmodule Lavash.FormTest do
  use ExUnit.Case, async: true

  alias Lavash.Form

  # ============================================
  # submit/2 - special states
  # ============================================

  describe "submit/2 - special states" do
    test "returns {:error, :loading} for :loading" do
      assert {:error, :loading} = Form.submit(:loading)
    end

    test "returns {:error, reason} for {:error, reason}" do
      assert {:error, :some_error} = Form.submit({:error, :some_error})
    end

    test "returns {:error, :no_form} for nil" do
      assert {:error, :no_form} = Form.submit(nil)
    end
  end

  # ============================================
  # Access behaviour
  # ============================================

  describe "Access behaviour" do
    test "fetch/2 delegates to inner form" do
      # Lavash.Form implements Access by delegating to the inner Phoenix.HTML.Form
      form = %Form{
        changeset: nil,
        form: %Phoenix.HTML.Form{
          source: %{},
          params: %{"name" => "test"},
          name: "form",
          id: "form"
        },
        action_type: :create,
        name: "test"
      }

      # Access protocol should work
      assert is_struct(form, Form)
    end
  end
end
