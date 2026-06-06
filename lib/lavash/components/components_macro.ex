defmodule Lavash.Components.ComponentsMacro do
  @moduledoc """
  Block-structured DSL for defining function components.

  Phoenix.Component's `attr` and `slot` macros attach themselves
  to the next-defined function via an `@on_definition` callback.
  That's positional — the schema lines must come immediately
  before the `def`, with nothing in between. Interleave anything
  and you get weird behaviour; refactoring moves attrs onto the
  wrong function silently.

  This block makes the function-to-schema relationship explicit:

      components do
        component :button do
          prop :rest, :global, include: ~w(disabled type)
          prop :class, :string, default: nil
          prop :variant, :atom, values: [:primary, :secondary], default: :primary
          slot :inner_block, required: true

          template do
            ~H\"\"\"
            <button class={["btn", "btn-\#{@variant}", @class]} {@rest}>
              {render_slot(@inner_block)}
            </button>
            \"\"\"
          end
        end

        component :badge do
          prop :label, :string, required: true
          prop :count, :integer, default: 0

          template do
            ~H\"\"\"
            <span class="badge">
              <span class="label">{@label}</span>
              <span :if={@count > 0} class="count">{@count}</span>
            </span>
            \"\"\"
          end
        end
      end

  Compiles to plain Phoenix function components — one `def`
  per `component` clause, with the Phoenix.Component.Declarative
  attribute/slot calls emitted immediately above. Consumers
  (other templates, other modules) call `<.button ...>` as
  normal — no runtime distinction.

  ## Vocabulary

  `prop` is lavash's term for what Phoenix.Component calls `attr`.
  Identical semantics — `prop :foo, :string, default: nil` becomes
  `attr :foo, :string, default: nil` in the compiled output. The
  reason for the rename: lavash already uses `prop` for parent-
  passed values in LiveComponents (`use Lavash.Component`).
  Standardising on `prop` across both kinds of component makes
  the DSL internally consistent. Coming from Phoenix, "prop = attr"
  is the only translation you need.

  `slot` is unchanged — same name, same options as Phoenix.Component.

  `template do ~H\"...\" end` is the function body. The `~H` template
  is compiled into the generated component's `def name(assigns)`, with
  `assigns` in scope. (Same result as Phoenix.Component's
  `def name(assigns), do: ~H\"...\"`.)
  """

  @doc """
  Top-level `components do ... end` block. Contains one or more
  `component/2` calls.
  """
  defmacro components(do: block) do
    quote do
      Module.register_attribute(__MODULE__, :__lavash_components__, accumulate: true)
      unquote(block)
    end
  end

  @doc """
  A single `component :name do ... end` clause. The body is a
  sequence of `prop` / `slot` declarations followed by a single
  `template do ~H\"...\" end`.
  """
  defmacro component(name, do: body) do
    {props, slots, template_body} = extract_component_parts(body)

    # Emit the Phoenix function component DIRECTLY at macro
    # expansion time. Deferring this to a Spark transformer via
    # `@before_compile` was tried — but by then the module is too
    # far along for Phoenix.Component's @on_definition hook to
    # attach attrs/slots to the generated def. Emitting here
    # keeps the attr/slot decoration paired with its def at
    # parse time, which is what Phoenix expects.
    attr_calls =
      Enum.map(props, fn {prop_name, prop_type, prop_opts} ->
        quote do
          attr(unquote(prop_name), unquote(prop_type), unquote(prop_opts))
        end
      end)

    slot_calls =
      Enum.map(slots, fn {slot_name, slot_opts} ->
        quote do
          slot(unquote(slot_name), unquote(slot_opts))
        end
      end)

    # We emit `Phoenix.Component.Declarative.def` explicitly rather
    # than plain `def`. `use Phoenix.Component` does
    # `import Kernel, except: [def: 2]` and imports
    # `Phoenix.Component.Declarative`, so the user-written `def`
    # is actually Phoenix's wrapper (which inserts `__pattern__!`
    # to consume the attrs queue). From inside this macro hygiene
    # resolves `def` to `Kernel.def`, bypassing the wrapper —
    # which leaves the attrs queue dangling and triggers a
    # "could not define attributes for function" error at compile
    # time. The fully-qualified call sidesteps the hygiene issue.
    #
    # The `~H` template body comes from the user's `template do ... end`
    # block. We name the def's parameter with a context-agnostic
    # `Macro.var(:assigns, nil)` so the spliced sigil body — which
    # references `assigns` by name during sigil expansion — resolves to
    # the same variable. (The former render-fn shape sidestepped this by
    # carrying its own closure binding.)
    assigns_var = Macro.var(:assigns, nil)

    quote do
      unquote_splicing(attr_calls)
      unquote_splicing(slot_calls)

      Phoenix.Component.Declarative.def unquote(name)(unquote(assigns_var)) do
        unquote(template_body)
      end
    end
  end

  # Walks the component body AST and extracts:
  #   * props :: list of {name, type, opts}
  #   * slots :: list of {name, opts, inner_attrs_or_nil}
  #   * template_body :: the `~H"..."` sigil AST from the `template do ... end` block
  defp extract_component_parts({:__block__, _, statements}) do
    do_extract(statements, [], [], nil)
  end

  defp extract_component_parts(single_statement) do
    do_extract([single_statement], [], [], nil)
  end

  defp do_extract([], props, slots, template_body) do
    if is_nil(template_body) do
      raise CompileError,
        description: "component must contain `template do ~H\"...\" end`"
    end

    {Enum.reverse(props), Enum.reverse(slots), template_body}
  end

  # prop :name, :type, opts? — two-arg or three-arg form
  defp do_extract([{:prop, _, [name, type]} | rest], props, slots, template_body) do
    do_extract(rest, [{name, type, []} | props], slots, template_body)
  end

  defp do_extract([{:prop, _, [name, type, opts]} | rest], props, slots, template_body) do
    do_extract(rest, [{name, type, opts} | props], slots, template_body)
  end

  # slot :name (one-arg form, no opts)
  defp do_extract([{:slot, _, [name]} | rest], props, slots, template_body) do
    do_extract(rest, props, [{name, []} | slots], template_body)
  end

  # slot :name, opts (two-arg form)
  defp do_extract([{:slot, _, [name, opts]} | rest], props, slots, template_body) do
    do_extract(rest, props, [{name, opts} | slots], template_body)
  end

  # template do ~H"..." end
  defp do_extract([{:template, _, [[do: block]]} | rest], props, slots, template_body) do
    if not is_nil(template_body) do
      raise CompileError,
        description: "component may declare only one `template`"
    end

    do_extract(rest, props, slots, block)
  end

  defp do_extract([unknown | _], _, _, _) do
    raise CompileError,
      description:
        "Unsupported statement inside `component do ... end`: " <>
          Macro.to_string(unknown) <>
          ". Allowed: `prop name, type, opts?`, `slot name, opts?`, " <>
          "`template do ~H\"...\" end`."
  end
end
