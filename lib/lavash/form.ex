defmodule Lavash.Form do
  @moduledoc """
  A wrapper around Ash.Changeset that provides both form rendering and submission.

  When a derived field returns an Ash.Changeset, Lavash automatically wraps it
  in this struct. This allows:
  - Rendering via Phoenix.HTML.FormData protocol (implemented by AshPhoenix.Form)
  - Submission via Ash.create/update/destroy

  The wrapper is transparent - you can pattern match on it or use it directly
  in templates via the `form` field.
  """

  defstruct [:changeset, :form]

  @doc """
  Creates a form for an Ash resource.

  If record is nil or has no id, creates a form for the create action.
  Otherwise creates a form for the update action.
  """
  def for_resource(resource, record, params, opts \\ []) do
    create_action = Keyword.get(opts, :create, :create)
    update_action = Keyword.get(opts, :update, :update)

    if is_nil(record) or is_nil(Map.get(record, :id)) do
      # Create new
      changeset = Ash.Changeset.for_create(resource, create_action, params)
      wrap(changeset)
    else
      # Update existing
      changeset = Ash.Changeset.for_update(record, update_action, params)
      wrap(changeset)
    end
  end

  @doc """
  Wraps an Ash.Changeset, creating both the form for rendering and preserving
  the changeset for submission.
  """
  def wrap(%Ash.Changeset{} = changeset) do
    # Create AshPhoenix.Form from the changeset
    ash_form = build_ash_form(changeset)

    # Convert to Phoenix.HTML.Form for template rendering
    phoenix_form = Phoenix.Component.to_form(ash_form)

    %__MODULE__{
      changeset: changeset,
      form: phoenix_form
    }
  end

  def wrap(other), do: other

  defp build_ash_form(%Ash.Changeset{} = changeset) do
    case changeset.action_type do
      :create ->
        AshPhoenix.Form.for_create(
          changeset.resource,
          changeset.action.name,
          params: changeset.params || %{}
        )

      :update ->
        AshPhoenix.Form.for_update(
          changeset.data,
          changeset.action.name,
          params: changeset.params || %{}
        )

      :destroy ->
        AshPhoenix.Form.for_destroy(
          changeset.data,
          changeset.action.name,
          params: changeset.params || %{}
        )

      _ ->
        # Fallback for other action types
        AshPhoenix.Form.for_action(
          changeset.data || changeset.resource,
          changeset.action.name,
          params: changeset.params || %{}
        )
    end
  end

  @doc """
  Submits the form by running the underlying Ash action.
  Returns {:ok, result} or {:error, changeset}.
  """
  def submit(%__MODULE__{changeset: changeset}) do
    case changeset.action_type do
      :create -> Ash.create(changeset)
      :update -> Ash.update(changeset)
      :destroy -> Ash.destroy(changeset)
      _ -> {:error, "Unknown action type: #{changeset.action_type}"}
    end
  end

  def submit(%Ash.Changeset{} = changeset) do
    case changeset.action_type do
      :create -> Ash.create(changeset)
      :update -> Ash.update(changeset)
      :destroy -> Ash.destroy(changeset)
      _ -> {:error, "Unknown action type: #{changeset.action_type}"}
    end
  end

  # Also support AshPhoenix.Form directly for backwards compatibility
  def submit(%AshPhoenix.Form{} = form) do
    AshPhoenix.Form.submit(form)
  end

  # Support Phoenix.HTML.Form by checking its source
  def submit(%Phoenix.HTML.Form{source: source}) do
    submit(source)
  end
end
