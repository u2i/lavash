defmodule Lavash.Transformers.ValidateDsl do
  @moduledoc """
  Compile-time validation of cross-entity references in the DSL.

  Catches a family of "typo or stale reference" errors that would otherwise
  surface as a runtime crash, a silent nil, or a quiet shadow — usually deep
  inside lavash's runtime where the user can't easily trace them back to the
  original mistake. Each check raises `Spark.Error.DslError` with the
  offending entity name and a hint at the fix.

  Run after `Lavash.Transformers.ExpandFields` (so all synthesized entities
  — animated phase states, setter actions, etc. — are present) and before
  any compile transformer.

  Checks:

  1. **`state` name uniqueness** — two `state :foo, ...` declarations are
     a silent shadow (second wins).
  2. **`calculate` name uniqueness** — two `calculate :foo, ...` likewise.
  3. **state/calculate name collision** — a calculation with the same name
     as a state silently masks the state.
  4. **`action` name uniqueness** — duplicate `action :foo do ... end`
     silently keeps only one.
  5. **`reads [:field]`** — references must match a state OR calculation.
     Today this surfaces as `KeyError` inside the run body.
  6. **`set :field, ...`** — target must be a declared state.
  7. **`set ..., rx(@field)` deps** — references inside rx must match
     declared states or calculations. Today an unknown @field evaluates
     to `nil` silently.
  8. **`calculate :foo, rx(@field)` deps** — same shape as #7.
  9. **Action guards (`action :foo, [], [:guard])`** — guard names must
     match a declared boolean state or calculation.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  # Run after every spec is materialised so synthetic entities are visible.
  def after?(Lavash.Optimistic.Transformers.ExpandAnimatedStates), do: true
  def after?(Lavash.Optimistic.Transformers.ExpandDefrx), do: true
  def after?(Lavash.Transformers.ExpandFields), do: true
  def after?(_), do: false

  def before?(Lavash.Component.Transformers.TokenizeTemplate), do: true
  def before?(Lavash.Component.Transformers.CompileComponent), do: true
  def before?(Lavash.LiveView.Transformers.CompileLiveView), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    states = entities(dsl_state, [:states])
    calculations = entities(dsl_state, [:calculations])
    actions = entities(dsl_state, [:actions])
    reads = entities(dsl_state, [:reads])
    forms = entities(dsl_state, [:forms])
    props = entities(dsl_state, [:props])

    state_names = MapSet.new(states, & &1.name)
    calc_names = MapSet.new(calculations, & &1.name)
    read_names = MapSet.new(reads, & &1.name)
    prop_names = MapSet.new(props, & &1.name)
    form_field_names = forms |> Enum.flat_map(&form_field_names/1) |> MapSet.new()

    # client_state projections resolve at runtime like reads do
    projection_names =
      reads
      |> Enum.flat_map(fn read -> Enum.map(read.client_states || [], & &1.name) end)
      |> MapSet.new()

    # Anything that resolves at runtime to a value the action body /
    # calculate body can read: declared state, declared calc, reads,
    # props (components), form-derived fields.
    known =
      state_names
      |> MapSet.union(calc_names)
      |> MapSet.union(read_names)
      |> MapSet.union(prop_names)
      |> MapSet.union(form_field_names)
      |> MapSet.union(projection_names)

    # `set` targets: declared state OR form-synthesized state fields
    # (e.g. `<form>_params` is an ephemeral state field the form
    # runtime maintains — modal injection clears it on open).
    writable = MapSet.union(state_names, form_field_names)

    with :ok <- check_unique(states, "state", module),
         :ok <- check_unique(calculations, "calculation", module),
         :ok <- check_unique(actions, "action", module),
         :ok <- check_state_calc_collision(state_names, calculations, module),
         :ok <- check_reads(actions, known, module),
         :ok <- check_action_sets(actions, writable, module),
         :ok <- check_action_set_deps(actions, known, module),
         :ok <- check_action_guards(actions, state_names, calc_names, module),
         :ok <- check_calc_deps(calculations, known, module) do
      {:ok, dsl_state}
    end
  end

  # --- entity helpers ---

  defp entities(dsl_state, path) do
    Transformer.get_entities(dsl_state, path) || []
  end

  @doc false
  def form_field_names(form) do
    base = form.name

    # The form itself is exposed under its declared name (e.g.
    # `form :edit_form, ...` → `@edit_form` is the AshPhoenix form
    # struct), plus the standard top-level derives.
    top_level = [
      base,
      :"#{base}_params",
      :"#{base}_action",
      :"#{base}_valid",
      :"#{base}_errors",
      :"#{base}_show_errors",
      :"#{base}_server_errors"
    ]

    # Per-field validators (`<form>_<field>_valid`, etc.) are
    # generated at JS-extract time from the Ash resource's
    # attributes. ValidateDsl runs earlier than that, so we
    # introspect the resource directly here.
    fields = form_fields_from_resource(form)

    per_field =
      Enum.flat_map(fields, fn field ->
        [
          :"#{base}_#{field}_valid",
          :"#{base}_#{field}_errors",
          :"#{base}_#{field}_show_errors"
        ]
      end)

    top_level ++ per_field
  end

  # Pull the attribute names off the form's Ash resource. The form
  # entity carries `:resource` (the Ash module). If the resource
  # isn't loaded yet (compile order edge case) or doesn't expose
  # the introspection API, fall back to `:fields` on the form entity.
  defp form_fields_from_resource(form) do
    resource = Map.get(form, :resource)

    if is_atom(resource) and function_exported?(resource, :spark_dsl_config, 0) do
      try do
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)
      rescue
        _ -> Map.get(form, :fields, []) || []
      end
    else
      Map.get(form, :fields, []) || []
    end
  end

  # --- uniqueness ---

  defp check_unique(entities, kind, module) do
    names = Enum.map(entities, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [duplicate | _] ->
        {:error,
         DslError.exception(
           module: module,
           path: [String.to_atom("#{kind}s"), duplicate],
           message:
             "#{kind} #{inspect(duplicate)} is declared more than once. " <>
               "Rename one of the declarations."
         )}
    end
  end

  # --- name collisions ---

  defp check_state_calc_collision(state_names, calculations, module) do
    collisions =
      calculations
      |> Enum.filter(&MapSet.member?(state_names, &1.name))
      |> Enum.map(& &1.name)

    case collisions do
      [] ->
        :ok

      [name | _] ->
        {:error,
         DslError.exception(
           module: module,
           path: [:calculations, name],
           message:
             "calculation #{inspect(name)} shares its name with a `state` of " <>
               "the same name. The calculation silently masks the state at " <>
               "runtime. Rename one of them."
         )}
    end
  end

  # --- reads ---

  defp check_reads(actions, known, module) do
    Enum.reduce_while(actions, :ok, fn action, _ ->
      reads = Map.get(action, :reads, []) || []

      case Enum.find(reads, &(not MapSet.member?(known, &1))) do
        nil ->
          {:cont, :ok}

        unknown ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:actions, action.name, :reads],
              message:
                "action #{inspect(action.name)} reads #{inspect(unknown)}, " <>
                  "but no state, calculation, read, or form field by that " <>
                  "name is declared. Check for a typo, or declare the " <>
                  "field first."
            )}}
      end
    end)
  end

  # --- action sets ---

  defp check_action_sets(actions, state_names, module) do
    Enum.reduce_while(actions, :ok, fn action, _ ->
      sets = action.sets || []

      case Enum.find(sets, &(not MapSet.member?(state_names, &1.field))) do
        nil ->
          {:cont, :ok}

        bad_set ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:actions, action.name, :sets],
              message:
                "action #{inspect(action.name)} sets #{inspect(bad_set.field)}, " <>
                  "but #{inspect(bad_set.field)} is not a declared `state`. " <>
                  "`set` writes to state — declare a `state #{inspect(bad_set.field)}, ...` " <>
                  "or use `run fn socket -> assign(socket, #{inspect(bad_set.field)}, ...) end` " <>
                  "if you want to write a transient assign."
            )}}
      end
    end)
  end

  defp check_action_set_deps(actions, known, module) do
    Enum.reduce_while(actions, :ok, fn action, _ ->
      action_params = MapSet.new(action.params || [])
      effective_known = MapSet.union(known, action_params)

      case find_bad_set_dep(action.sets || [], effective_known) do
        nil ->
          {:cont, :ok}

        {bad_set, unknown_dep} ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:actions, action.name, :sets, bad_set.field],
              message:
                "action #{inspect(action.name)} `set #{inspect(bad_set.field)}, " <>
                  "rx(...)` references @#{unknown_dep}, but no state, " <>
                  "calculation, action param, or form field by that name " <>
                  "exists in this module. Check for a typo."
            )}}
      end
    end)
  end

  defp find_bad_set_dep(sets, known) do
    Enum.find_value(sets, fn set ->
      case set.value do
        %Lavash.Rx{deps: deps} ->
          case Enum.find(normalize_deps(deps), &(not MapSet.member?(known, &1))) do
            nil -> nil
            unknown -> {set, unknown}
          end

        _ ->
          nil
      end
    end)
  end

  # --- action guards ---

  defp check_action_guards(actions, state_names, calc_names, module) do
    bool_capable = MapSet.union(state_names, calc_names)

    Enum.reduce_while(actions, :ok, fn action, _ ->
      guards = action.when || []

      case Enum.find(guards, &(not MapSet.member?(bool_capable, &1))) do
        nil ->
          {:cont, :ok}

        unknown ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:actions, action.name, :when],
              message:
                "action #{inspect(action.name)} guard #{inspect(unknown)} " <>
                  "is not a declared state or calculation. Guards must " <>
                  "reference a boolean field that determines whether the " <>
                  "action fires."
            )}}
      end
    end)
  end

  # --- calculation deps ---

  defp check_calc_deps(calculations, known, module) do
    Enum.reduce_while(calculations, :ok, fn calc, _ ->
      deps = calc.rx.deps || []

      case Enum.find(normalize_deps(deps), &(not MapSet.member?(known, &1))) do
        nil ->
          {:cont, :ok}

        unknown ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:calculations, calc.name],
              message:
                "calculation #{inspect(calc.name)} references @#{unknown}, " <>
                  "but no state, calculation, read, or form field by that " <>
                  "name exists in this module. Check for a typo or declare " <>
                  "the field first."
            )}}
      end
    end)
  end

  # rx deps are a list of `:atom` and `{:path, :atom, [...]}` tuples; we
  # only care about the root name for ref validation.
  defp normalize_deps(deps) do
    Enum.map(deps, fn
      {:path, name, _path} -> name
      name when is_atom(name) -> name
    end)
  end
end
