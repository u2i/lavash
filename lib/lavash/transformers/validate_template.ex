defmodule Lavash.Transformers.ValidateTemplate do
  @moduledoc """
  Compile-time validation of template-level references against the DSL.

  Where `Lavash.Transformers.ValidateDsl` checks entity-internal
  references (rx body deps, action `reads:` lists, set targets, calc
  deps), this transformer checks **template** references — things the
  user writes in HEEx that resolve to DSL-declared names at runtime.

  ## What's validated

  - **`phx-click="action_name"`** (and `phx-submit`, `phx-change`,
    `phx-blur`, `phx-focus`, `phx-keydown`, `phx-keyup`,
    `phx-window-keydown`, `phx-window-keyup`) on plain HTML tags
    must refer to a declared `action :name` on the module (or an
    auto-generated setter from `state :name, setter: true` /
    `optimistic: true`).

  - **`phx-value-<key>="..."`** attributes on the same node as a
    phx-event must correspond to a declared `params [...]` entry on
    the action. So `<button phx-click="bump_by"
    phx-value-amount="5">` is valid only if `:bump_by` was declared
    as `action :bump_by, [:amount] do ... end`. Catches typo'd value
    keys whose runtime symptom is "the action body receives a nil
    param and crashes inside `String.to_integer(nil)`."

  - **`@name` assign references** anywhere an Elixir expression
    appears in HEEx (`{@field}`, `:if={@open}`, `class={@theme}`,
    `<%= @count %>`, etc.). Every reference must resolve to one of:

      * a declared `state` field (including `from: :assigns` ones)
      * a `Phoenix.Component` attr or slot declared on the module
      * a Phoenix-injected assign (`@flash`, `@socket`,
        `@live_action`, `@uploads`, `@streams`, `@myself`,
        `@inner_block`, `@__changed__`, `@__given__`)

    Catches typos like `{@flsh[:info]}` whose runtime symptom is
    silent nil — or a `KeyError` deep inside a render that doesn't
    point at the template. Bare variable references (e.g. `item`
    inside `:for={item <- @items}`) are ignored: they're Elixir
    locals, not assigns, and the compiler catches undefined ones
    itself.

  ## What's not validated

  - **Dynamic event values** like `phx-click={@some_var}` or
    `phx-click={JS.dispatch(...)}` — the AST is an expression, not a
    static string. We can't know at compile time whether the runtime
    value resolves to a server event name or a JS command. When the
    phx-event itself is dynamic, the phx-value-* check is also
    skipped (we don't know which action to check against).

  - **Events on component nodes** like
    `<.my_component phx-click="...">`. The attribute binds to a
    prop, not an event handler on the host module. Component-level
    events are validated when the component itself compiles.

  - **Modules using `def render(assigns)` without `template do`**.
    No token pipeline runs, no extraction, no validation.

  ## Ordering

  Runs after `AnalyzeTemplate` (which collects template event
  references into `:lavash_template_phx_events`) and before the
  Compile{Component,LiveView} transformers.
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  # Phoenix lets `set_<name>` auto-setters consume `phx-value-value`
  # (the params dispatcher reads .value). Hard-coded because the
  # setters aren't first-class action structs at validation time.
  @auto_setter_params ["value"]

  def after?(Lavash.Component.Transformers.AnalyzeTemplate), do: true
  def after?(Lavash.Transformers.ValidateDsl), do: true
  # The overlay render generators persist :modal_render_template /
  # :flyover_render_template, which overlay_assigns/1 reads to whitelist
  # the injected assigns (@__modal_id__, @__flyover_id__). Without an
  # explicit edge the topo sort's tie-break decides — and it differs
  # across Elixir versions (1.18 ran this validator first, flagging
  # @__flyover_id__ as undeclared; 1.19 happened to order it correctly).
  def after?(Lavash.Overlay.Modal.Transformers.GenerateRender), do: true
  def after?(Lavash.Overlay.Flyover.Transformers.GenerateRender), do: true
  def after?(_), do: false

  def before?(Lavash.Component.Transformers.CompileComponent), do: true
  def before?(Lavash.LiveView.Transformers.CompileLiveView), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    events = Transformer.get_persisted(dsl_state, :lavash_template_phx_events) || []
    assign_refs = Transformer.get_persisted(dsl_state, :lavash_template_assign_refs) || []

    if events == [] and assign_refs == [] do
      {:ok, dsl_state}
    else
      action_index = build_action_index(dsl_state)
      valid_assigns = build_valid_assigns(dsl_state, module)

      with :ok <- check_event_names(events, action_index, module),
           :ok <- check_phx_values(events, action_index, module),
           :ok <- check_assign_refs(assign_refs, valid_assigns, module) do
        {:ok, dsl_state}
      end
    end
  end

  # Map: action_name (string) → list of param atoms accepted. Includes
  # declared actions, auto-generated setters, and the auto-generated
  # `validate_{form}` form-change handlers.
  defp build_action_index(dsl_state) do
    actions = Transformer.get_entities(dsl_state, [:actions]) || []
    states = Transformer.get_entities(dsl_state, [:states]) || []
    forms = Transformer.get_entities(dsl_state, [:forms]) || []

    declared =
      Map.new(actions, fn action ->
        params = (action.params || []) |> Enum.map(&to_string/1)
        {to_string(action.name), params}
      end)

    auto_setters =
      states
      |> Enum.filter(&setter_field?/1)
      |> Map.new(fn field ->
        {"set_#{field.name}", @auto_setter_params}
      end)

    # Each form gets an auto-generated `validate_{form}` change handler
    # (see Lavash.LiveView.Runtime) — accept it on plain HTML tags too,
    # not just on <.form> component nodes (which skip validation).
    form_validators = Map.new(forms, fn form -> {"validate_#{form.name}", []} end)

    # User-declared actions take precedence: if a user wrote
    # `action :set_count, [:amount] do ... end`, that's the
    # authoritative shape — even if `:count` would otherwise have
    # auto-generated a `set_count` setter with `:value`.
    auto_setters
    |> Map.merge(form_validators)
    |> Map.merge(declared)
  end

  defp setter_field?(%{setter: true}), do: true
  defp setter_field?(%{optimistic: true}), do: true

  defp setter_field?(%{animated: animated}) when animated not in [nil, false],
    do: true

  defp setter_field?(_), do: false

  # `events` is a list of per-node tuples:
  #   {[{action_name, event_meta}, ...], phx_value_keys, node_meta}
  #
  # We flatten across all nodes for the event-name check (each
  # individual phx-event must reference a known action), then check
  # phx-value-* per-node (a key is valid as long as at least one of
  # the node's events declares it in params).

  defp check_event_names(nodes, action_index, module) do
    nodes
    |> Enum.flat_map(fn {events, _vkeys, _node_meta} -> events end)
    |> Enum.find(fn {name, _meta} -> not Map.has_key?(action_index, name) end)
    |> case do
      nil ->
        :ok

      {name, meta} ->
        {:error, build_unknown_action_error(name, meta, Map.keys(action_index), module)}
    end
  end

  defp check_phx_values(nodes, action_index, module) do
    bad =
      Enum.find_value(nodes, fn {events, vkeys, node_meta} ->
        # Union of declared params across all events on this node.
        accepted_keys =
          events
          |> Enum.flat_map(fn {name, _meta} -> Map.fetch!(action_index, name) end)
          |> Enum.uniq()

        case Enum.find(vkeys, fn key -> key not in accepted_keys end) do
          nil ->
            nil

          extra_key ->
            event_names = Enum.map(events, fn {n, _} -> n end)
            {event_names, extra_key, accepted_keys, node_meta}
        end
      end)

    case bad do
      nil ->
        :ok

      {event_names, extra_key, accepted_keys, meta} ->
        {:error,
         build_unknown_phx_value_error(event_names, extra_key, accepted_keys, meta, module)}
    end
  end

  # ============================================
  # Assign-ref validation
  # ============================================

  # Assigns Phoenix's runtime / `Phoenix.Component` machinery injects into
  # every LiveView/Component render scope. None of these are lavash-declared
  # state, but referencing them in HEEx is legitimate. Treat them as
  # always-valid so the validator doesn't false-positive on
  # `{@flash[:info]}`, `:if={@live_action == :index}`, etc.
  @phoenix_injected_assigns ~w(
    socket
    flash
    live_action
    uploads
    streams
    id
    myself
    inner_block
    __changed__
    __given__
  )a

  # Build the set of every assign name (as atom) the validator should
  # accept in HEEx. Union of:
  #
  #   * lavash-declared `state` fields (including `from: :assigns` ones,
  #     which use the local `state :name` as the assign name)
  #   * lavash-declared `prop` entries (caller-provided component props)
  #   * `@phoenix_injected_assigns` — hardcoded Phoenix-supplied keys
  #   * `Phoenix.Component` attrs and slots declared on the module
  #     (rare for LiveViews, common for modules using `component :name do`)
  defp build_valid_assigns(dsl_state, module) do
    states = Transformer.get_entities(dsl_state, [:states]) || []
    state_names = Enum.map(states, & &1.name)

    props = Transformer.get_entities(dsl_state, [:props]) || []
    prop_names = Enum.map(props, & &1.name)

    slots = Transformer.get_entities(dsl_state, [:slots]) || []
    slot_names = Enum.map(slots, & &1.name)

    calcs = Transformer.get_entities(dsl_state, [:calculations]) || []
    calc_names = Enum.map(calcs, & &1.name)

    # `async :name do ... end` registers `@__lavash_async_defs__`
    # entries as `{:__async__, name, run_fn_ast}`. The name lands on
    # assigns as an `%AsyncResult{}` and is legitimately referenced
    # in templates.
    async_defs = Module.get_attribute(module, :__lavash_async_defs__) || []
    async_names = for {:__async__, n, _} <- async_defs, do: n

    # `read :foo, Resource do ... end` exposes `@foo` on assigns
    # (either as the value directly when `async: false`, or as an
    # `%AsyncResult{}` otherwise).
    reads = Transformer.get_entities(dsl_state, [:reads]) || []
    read_names = Enum.map(reads, & &1.name)

    # client_state projections land on assigns as derived lists
    projection_names =
      Enum.flat_map(reads, fn read -> Enum.map(read.client_states || [], & &1.name) end)

    forms = Transformer.get_entities(dsl_state, [:forms]) || []
    form_names = Enum.flat_map(forms, &form_assigns/1)

    # Overlay extensions (modal, flyover): when declared, the
    # generated render wraps the user's template with extra assigns
    # injected by the overlay's RenderGenerator. The `async_assign`
    # clause additionally binds `@form` to the unwrapped async value.
    overlay_assigns = overlay_assigns(dsl_state)

    phoenix_attrs_slots = phoenix_component_attrs_and_slots(module)

    MapSet.new(
      state_names ++
        prop_names ++
        slot_names ++
        calc_names ++
        async_names ++
        read_names ++
        projection_names ++
        form_names ++
        overlay_assigns ++
        @phoenix_injected_assigns ++
        phoenix_attrs_slots
    )
  end

  # Names a form contributes to template scope. Mirrors
  # `Lavash.Transformers.ValidateDsl.form_field_names/1` — keep the
  # two in sync if either grows. Per-field validators come from
  # introspecting the Ash resource.
  # Modal- and flyover-extension injected assigns. Both wrap the
  # user's template render and inject the same shape of metadata
  # assigns via `Phoenix.Component.assign/3` — they're legitimate
  # template refs but not declared in the user's DSL surface.
  defp overlay_assigns(dsl_state) do
    has_modal = Transformer.get_persisted(dsl_state, :modal_render_template) != nil
    has_flyover = Transformer.get_persisted(dsl_state, :flyover_render_template) != nil

    modal_keys =
      if has_modal do
        [
          :__modal_id__,
          :__modal_module__,
          :__modal_open__,
          :__modal_phase__,
          :__modal_open_field__,
          :__modal_close_on_escape__,
          :__modal_close_on_backdrop__,
          :__modal_max_width__,
          :__modal_render__,
          :__modal_loading__,
          :__modal_async_assign__
        ]
      else
        []
      end

    flyover_keys =
      if has_flyover do
        [
          :__flyover_id__,
          :__flyover_module__,
          :__flyover_open__,
          :__flyover_phase__,
          :__flyover_open_field__,
          :__flyover_slide_from__,
          :__flyover_close_on_escape__,
          :__flyover_close_on_backdrop__,
          :__flyover_width__,
          :__flyover_height__,
          :__flyover_render__,
          :__flyover_loading__,
          :__flyover_async_assign__
        ]
      else
        []
      end

    shared =
      if has_modal or has_flyover do
        [
          :on_close,
          :__lavash_module__,
          :__lavash_state__,
          :__lavash_version__,
          :__lavash_animated__,
          :__lavash_bindings__
        ]
      else
        []
      end

    async_form =
      case {Transformer.get_persisted(dsl_state, :modal_async_assign),
            Transformer.get_persisted(dsl_state, :flyover_async_assign)} do
        {nil, nil} -> []
        _ -> [:form]
      end

    modal_keys ++ flyover_keys ++ shared ++ async_form
  end

  defp form_assigns(form) do
    base = form.name

    top_level = [
      base,
      :"#{base}_params",
      :"#{base}_action",
      :"#{base}_valid",
      :"#{base}_errors",
      :"#{base}_show_errors",
      :"#{base}_server_errors"
    ]

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

  # `Phoenix.Component` stashes declared attrs in `@__attrs__` and slots
  # in `@__slots__` (as module attributes) at attr/slot macro call time.
  # By the time Spark transformers run, those attributes may have been
  # consumed by `Phoenix.Component.Declarative.def`, which moves them
  # into the actual function's metadata. We try both surfaces.
  defp phoenix_component_attrs_and_slots(module) do
    # Module attributes are still readable during DSL transformation;
    # they're consumed when the module finishes compiling. If the
    # module has any pending attrs/slots, pull their names.
    attrs = Module.get_attribute(module, :__attrs__) || []
    slots = Module.get_attribute(module, :__slots__) || []

    Enum.map(attrs, & &1[:name]) ++ Enum.map(slots, & &1[:name])
  rescue
    # `Module.get_attribute/2` raises if the module is no longer open
    # (rare for transformers but possible for `use Lavash.Component`
    # nested in another macro). Fall back to empty list — false
    # positives on slot refs are tolerable; crashing the build isn't.
    _ -> []
  end

  defp check_assign_refs(refs, valid_assigns, module) do
    case Enum.find(refs, fn {name, _meta} -> not MapSet.member?(valid_assigns, name) end) do
      nil ->
        :ok

      {name, meta} ->
        {:error, build_unknown_assign_error(name, meta, MapSet.to_list(valid_assigns), module)}
    end
  end

  defp build_unknown_assign_error(name, meta, valid_names, module) do
    candidates = Enum.map(valid_names, &to_string/1)
    suggestion = closest_name(name, candidates)

    suggestion_hint =
      if suggestion do
        "\n\nDid you mean `@#{suggestion}`?"
      else
        ""
      end

    line_hint =
      case meta do
        %{line: line} -> " (line #{line})"
        _ -> ""
      end

    %Spark.Error.DslError{
      module: module,
      path: [:template],
      message: """
      `@#{name}` references an undeclared assign#{line_hint}.

      The template uses `@#{name}` but it isn't a declared `state`
      field, a `Phoenix.Component` attr/slot on this module, or one
      of the Phoenix-injected assigns
      (#{Enum.map_join(@phoenix_injected_assigns, ", ", &"`@#{&1}`")}).

      At runtime this would read `nil` from `assigns`, or raise a
      `KeyError` under `assigns[:strict_keys?]`.

      Either:

        - Add `state :#{name}, :type, ...` to declare it as
          lavash-managed state
        - Add `state :#{name}, :type, from: :assigns,
          assigns_key: :#{name}` to lift it from an `on_mount`
          hook into lavash state
        - Fix the typo in the template#{suggestion_hint}
      """
    }
  end

  defp build_unknown_action_error(name, meta, declared_names, module) do
    suggestion = closest_name(name, declared_names)

    suggestion_hint =
      if suggestion do
        "\n\nDid you mean `#{suggestion}`?"
      else
        ""
      end

    line_hint =
      case meta do
        %{line: line} -> " (line #{line})"
        _ -> ""
      end

    %Spark.Error.DslError{
      module: module,
      path: [:template],
      message: """
      phx-event references undeclared action `#{name}`#{line_hint}.

      The template references an event handler that isn't declared in
      this module. Either:

        - Add `action :#{name} do ... end` to the `actions do` block
        - Add `state :#{name}, ..., setter: true` to auto-generate a
          setter action
        - Fix the typo in the template#{suggestion_hint}

      If the value is intentionally not a lavash action (e.g. it's
      handled by a separate Phoenix.LiveView module, or by a
      JS.dispatch command), make the attribute value an expression
      instead of a static string so the validator skips it:

          phx-click={"#{name}"}
      """
    }
  end

  defp build_unknown_phx_value_error(event_names, extra_key, accepted_keys, meta, module) do
    suggestion = closest_name(extra_key, accepted_keys)

    suggestion_hint =
      if suggestion do
        "\n\nDid you mean `phx-value-#{suggestion}`?"
      else
        ""
      end

    events_display =
      case event_names do
        [single] -> "Action `#{single}`"
        many -> "None of the node's actions (#{Enum.map_join(many, ", ", &"`#{&1}`")})"
      end

    params_display =
      case accepted_keys do
        [] -> "#{events_display} declares no params."
        keys -> "#{events_display} accepts: #{Enum.map_join(keys, ", ", &"`#{&1}`")}."
      end

    line_hint =
      case meta do
        %{line: line} -> " (line #{line})"
        _ -> ""
      end

    target_action = List.first(event_names)

    %Spark.Error.DslError{
      module: module,
      path: [:template],
      message: """
      `phx-value-#{extra_key}` references an undeclared param#{line_hint}.

      #{params_display}

      The runtime would receive this attribute as `params["#{extra_key}"]`
      in `handle_event`, but no action handler on this node declares it
      in its params list — the value would be silently dropped, or the
      action would crash trying to read a nil value.

      Either:

        - Add `:#{extra_key}` to one of the actions' params lists:
          `action :#{target_action}, [:#{extra_key}#{params_suffix(accepted_keys)}] do ... end`
        - Remove `phx-value-#{extra_key}` from the template
        - Fix the typo#{suggestion_hint}
      """
    }
  end

  defp params_suffix([]), do: ""
  defp params_suffix(params), do: ", :" <> Enum.join(params, ", :")

  # Best-effort typo suggestion: prefer the candidate with the smallest
  # Levenshtein distance. Returns nil if no close match.
  # Pick the closest match using `String.jaro_distance/2`. The
  # previous implementation used a naive recursive Levenshtein
  # (`lev/2` calling itself 3× without memoization) which is
  # exponential in string length — it stalled the compiler for
  # several minutes on a template with ~30 long-named assigns
  # (~25 chars each). Jaro is built into Elixir, runs in linear
  # time, and is plenty good for "did you mean?" suggestions.
  defp closest_name(name, candidates) do
    name_str = to_string(name)

    {best, score} =
      Enum.reduce(candidates, {nil, 0.0}, fn candidate, {_best, best_score} = acc ->
        s = String.jaro_distance(name_str, candidate)
        if s > best_score, do: {candidate, s}, else: acc
      end)

    # 0.85 picked empirically: catches typo'd `subtot` → `subtotal`
    # and `card_numbe` → `card_number` while rejecting unrelated
    # names like `total_display` vs. `tax`.
    if best && score >= 0.85, do: best, else: nil
  end
end
