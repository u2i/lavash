defmodule Lavash.Form do
  @moduledoc """
  A wrapper around Ash.Changeset that provides both form rendering and submission.

  When a derived field returns an Ash.Changeset, Lavash automatically wraps it
  in this struct. This allows:
  - Rendering via Phoenix.HTML.FormData protocol (implemented by AshPhoenix.Form)
  - Submission via Ash.create/update/destroy

  The wrapper is transparent to templates — it implements the `Access` behaviour
  (delegating `form[:field]` to the inner `Phoenix.HTML.Form`) and the
  `Phoenix.HTML.FormData` protocol (so `<.form for={@my_form}>` works directly).
  """

  @behaviour Access

  defstruct [:changeset, :form, :action_type, :name]

  # --- Access behaviour (delegate to inner Phoenix.HTML.Form) ---

  @impl Access
  def fetch(%__MODULE__{form: form}, key) do
    Phoenix.HTML.Form.fetch(form, key)
  end

  @impl Access
  def get_and_update(%__MODULE__{}, _key, _fun) do
    raise ArgumentError, "cannot update a Lavash.Form via Access"
  end

  @impl Access
  def pop(%__MODULE__{}, _key) do
    raise ArgumentError, "cannot pop from a Lavash.Form"
  end

  @doc """
  Creates a form for an Ash resource.

  If record is nil or has no id, creates a form for the create action.
  Otherwise creates a form for the update action.

  Options:
    - :create - the create action name (default: :create)
    - :update - the update action name (default: :update)
    - :as - the form name for params namespacing (default: "form")
  """
  def for_resource(resource, record, params, opts \\ []) do
    create_action = Keyword.get(opts, :create, :create)
    update_action = Keyword.get(opts, :update, :update)
    form_name = Keyword.get(opts, :as, "form")

    if is_nil(record) or is_nil(Map.get(record, :id)) do
      # Create new
      changeset = Ash.Changeset.for_create(resource, create_action, params)
      wrap(changeset, form_name)
    else
      # Update existing
      changeset = Ash.Changeset.for_update(record, update_action, params)
      wrap(changeset, form_name)
    end
  end

  @doc """
  Wraps an Ash.Changeset, creating both the form for rendering and preserving
  the changeset for submission.
  """
  def wrap(changeset, form_name \\ "form")

  def wrap(%Ash.Changeset{} = changeset, form_name) do
    # Create AshPhoenix.Form from the changeset
    ash_form = build_ash_form(changeset, form_name)

    # Convert to Phoenix.HTML.Form for template rendering
    phoenix_form = Phoenix.Component.to_form(ash_form)

    %__MODULE__{
      changeset: changeset,
      form: phoenix_form,
      action_type: changeset.action_type,
      name: form_name
    }
  end

  def wrap(other, _form_name), do: other

  defp build_ash_form(%Ash.Changeset{} = changeset, form_name) do
    # Only pass params if there are actual user-provided params
    # Empty params would override the record's existing values
    params_opt =
      case changeset.params do
        nil -> []
        params when params == %{} -> []
        params -> [params: params]
      end

    base_opts = [as: form_name] ++ params_opt

    case changeset.action_type do
      :create ->
        AshPhoenix.Form.for_create(
          changeset.resource,
          changeset.action.name,
          base_opts
        )

      :update ->
        AshPhoenix.Form.for_update(
          changeset.data,
          changeset.action.name,
          base_opts
        )

      :destroy ->
        AshPhoenix.Form.for_destroy(
          changeset.data,
          changeset.action.name,
          base_opts
        )

      _ ->
        # Fallback for other action types
        AshPhoenix.Form.for_action(
          changeset.data || changeset.resource,
          changeset.action.name,
          base_opts
        )
    end
  end

  @doc """
  Submits the form by running the underlying Ash action.
  Returns {:ok, result} or {:error, changeset}.

  Options:
    - :actor - The actor to use for authorization
  """
  def submit(form, opts \\ [])

  def submit(%__MODULE__{changeset: changeset}, opts) do
    actor = Keyword.get(opts, :actor)

    # Rebuild changeset with actor so relate_actor and other actor-dependent
    # changes have access to the actor context
    changeset =
      if actor do
        resource = changeset.resource
        action = changeset.action.name
        params = changeset.attributes

        case changeset.action_type do
          :create ->
            Ash.Changeset.for_create(resource, action, params, actor: actor)

          :update ->
            Ash.Changeset.for_update(changeset.data, action, params, actor: actor)

          _ ->
            changeset
        end
      else
        changeset
      end

    run_action(changeset, actor)
  end

  def submit(%Ash.Changeset{} = changeset, opts) do
    run_action(changeset, Keyword.get(opts, :actor))
  end

  # Also support AshPhoenix.Form directly for backwards compatibility
  def submit(%AshPhoenix.Form{} = form, opts) do
    actor = Keyword.get(opts, :actor)
    AshPhoenix.Form.submit(form, actor: actor)
  end

  # Support Phoenix.HTML.Form by checking its source
  def submit(%Phoenix.HTML.Form{source: source}, opts) do
    submit(source, opts)
  end

  # Handle special states that shouldn't be submitted
  def submit(:loading, _opts), do: {:error, :loading}
  def submit({:error, _} = err, _opts), do: err
  def submit(nil, _opts), do: {:error, :no_form}

  defp run_action(changeset, actor) do
    case changeset.action_type do
      :create -> Ash.create(changeset, actor: actor)
      :update -> Ash.update(changeset, actor: actor)
      :destroy -> Ash.destroy(changeset, actor: actor)
      _ -> {:error, "Unknown action type: #{changeset.action_type}"}
    end
  end
end

defimpl Phoenix.HTML.FormData, for: Lavash.Form do
  def to_form(%Lavash.Form{form: form}, opts) do
    Phoenix.Component.to_form(form, opts)
  end

  def to_form(%Lavash.Form{form: form}, form_struct, field, opts) do
    Phoenix.HTML.FormData.to_form(form, form_struct, field, opts)
  end

  def input_value(%Lavash.Form{form: form}, form_struct, field) do
    Phoenix.HTML.FormData.input_value(form, form_struct, field)
  end

  def input_validations(%Lavash.Form{form: form}, form_struct, field) do
    Phoenix.HTML.FormData.input_validations(form, form_struct, field)
  end
end
