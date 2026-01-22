defmodule Lavash.Component.Compiler do
  @moduledoc """
  Compiles the Lavash Component DSL into LiveComponent callbacks.
  """

  # Track helpers.ex as an external resource so changes trigger recompilation
  # of all modules that use the modal/flyover DSL. Path.expand with __DIR__ gives us
  # the absolute path at compile time of this module (in lavash's lib dir).
  @modal_helpers_path Path.expand("../overlay/modal/helpers.ex", __DIR__)
  @flyover_helpers_path Path.expand("../overlay/flyover/helpers.ex", __DIR__)

  defmacro __before_compile__(env) do
    modal_render = Spark.Dsl.Extension.get_persisted(env.module, :modal_render_template)
    flyover_render = Spark.Dsl.Extension.get_persisted(env.module, :flyover_render_template)

    # Get optimistic colocated data if available (persisted by ColocatedTransformer)
    # Escape immediately to avoid "tried to unquote invalid AST" errors during incremental compilation
    optimistic_colocated_data =
      case Spark.Dsl.Extension.get_persisted(env.module, :lavash_optimistic_colocated_data) do
        nil -> nil
        data -> Macro.escape(data)
      end

    render_function =
      cond do
        modal_render ->
          generate_modal_render(env.module)

        flyover_render ->
          generate_flyover_render(env.module)

        true ->
          quote do
          end
      end

    quote do
      @impl Phoenix.LiveComponent
      def update(assigns, socket) do
        Lavash.Component.Runtime.update(__MODULE__, assigns, socket)
      end

      @impl Phoenix.LiveComponent
      def handle_event(event, params, socket) do
        Lavash.Component.Runtime.handle_event(__MODULE__, event, params, socket)
      end

      unquote(render_function)

      # Introspection functions - entities from top_level? sections
      def __lavash__(:props) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:props])
      end

      def __lavash__(:states) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:states])
      end

      def __lavash__(:reads) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:reads])
      end

      def __lavash__(:forms) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:forms])
      end

      def __lavash__(:derived_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derives])
        |> Enum.map(&Lavash.LiveView.Compiler.normalize_derived/1)
      end

      def __lavash__(:calculations) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
      end

      # Expose calculations for Graph module
      # Returns 7-tuples: {name, source, ast, deps, optimistic, async, reads}
      def __lavash_calculations__ do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:calculations])
        |> Enum.map(fn calc ->
          {calc.name, calc.rx.source, calc.rx.ast, calc.rx.deps,
           Map.get(calc, :optimistic, true),
           Map.get(calc, :async, false),
           Map.get(calc, :reads, [])}
        end)
      end

      def __lavash__(:actions) do
        declared_actions = Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
        setter_actions = Lavash.LiveView.Compiler.generate_setter_actions(__MODULE__)
        declared_actions ++ setter_actions
      end

      # Convenience accessors by storage type
      def __lavash__(:socket_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :socket))
      end

      def __lavash__(:ephemeral_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.from == :ephemeral))
      end

      def __lavash__(:optimistic_fields) do
        __lavash__(:states) |> Enum.filter(&(&1.optimistic == true))
      end

      # Components don't have URL fields
      def __lavash__(:url_fields), do: []

      # Phoenix colocated JS integration for optimistic functions
      if unquote(not is_nil(optimistic_colocated_data)) do
        # optimistic_colocated_data is already escaped, so just unquote it directly
        @__lavash_optimistic_colocated_data__ unquote(optimistic_colocated_data)
        def __phoenix_macro_components__ do
          %{
            Phoenix.LiveView.ColocatedJS => [@__lavash_optimistic_colocated_data__]
          }
        end
      end
    end
  end

  defp generate_modal_render(module) do
    open_field = Spark.Dsl.Extension.get_persisted(module, :modal_open_field) || :open
    close_on_escape = Spark.Dsl.Extension.get_persisted(module, :modal_close_on_escape) || true

    close_on_backdrop =
      Spark.Dsl.Extension.get_persisted(module, :modal_close_on_backdrop) || true

    max_width = Spark.Dsl.Extension.get_persisted(module, :modal_max_width) || :md
    async_assign = Spark.Dsl.Extension.get_persisted(module, :modal_async_assign)
    helpers_path = @modal_helpers_path

    # Get animated fields config at compile time for JS consumption
    animated_fields = Spark.Dsl.Extension.get_persisted(module, :lavash_animated_fields) || []

    animated_json =
      animated_fields
      |> Enum.map(fn config ->
        %{
          field: to_string(config.field),
          phaseField: to_string(config.phase_field),
          async: config.async && to_string(config.async),
          preserveDom: config.preserve_dom,
          duration: config.duration,
          type: config.type && to_string(config.type)
        }
      end)
      |> Jason.encode!()

    quote do
      # Track helpers.ex so changes trigger recompilation of this module
      @external_resource unquote(helpers_path)
      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        import Lavash.Overlay.Modal.Helpers

        open_field = unquote(open_field)
        open_value = Map.get(var!(assigns), open_field)

        # Get the render functions from the DSL at runtime
        render_fn = Spark.Dsl.Extension.get_persisted(__MODULE__, :modal_render_template)
        loading_fn = Spark.Dsl.Extension.get_persisted(__MODULE__, :modal_render_loading_template)
        async_assign_field = unquote(async_assign)

        # Default loading function
        default_loading_fn = &Lavash.Overlay.Modal.Helpers.default_loading/1

        # Build modal ID from component ID
        modal_id = "#{Map.get(var!(assigns), :id, "modal")}-modal"

        # Build the on_close JS command for use in render functions
        on_close =
          Phoenix.LiveView.JS.dispatch("close-panel", to: "##{modal_id}")
          |> Phoenix.LiveView.JS.push("close", target: var!(assigns).myself)

        # Build optimistic state for data attribute (passive, no hook)
        optimistic_state = Lavash.Component.Helpers.optimistic_state(__MODULE__, var!(assigns))
        module_name = inspect(__MODULE__)
        optimistic_json = Lavash.JSON.encode!(optimistic_state)

        # Get optimistic version from socket
        version = Lavash.Socket.optimistic_version(var!(assigns).socket)

        # Get client bindings for parent-to-child propagation
        # This maps local field -> parent field for optimistic updates
        client_bindings = Map.get(var!(assigns), :__lavash_client_bindings__) || %{}
        bindings_json = Lavash.JSON.encode!(client_bindings)

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:__modal_id__, modal_id)
          |> Phoenix.Component.assign(:__modal_module__, __MODULE__)
          |> Phoenix.Component.assign(:on_close, on_close)
          |> Phoenix.Component.assign(:__modal_open__, open_value)
          |> Phoenix.Component.assign(:__modal_open_field__, unquote(open_field))
          |> Phoenix.Component.assign(:__modal_close_on_escape__, unquote(close_on_escape))
          |> Phoenix.Component.assign(:__modal_close_on_backdrop__, unquote(close_on_backdrop))
          |> Phoenix.Component.assign(:__modal_max_width__, unquote(max_width))
          |> Phoenix.Component.assign(:__modal_render__, render_fn)
          |> Phoenix.Component.assign(:__modal_loading__, loading_fn || default_loading_fn)
          |> Phoenix.Component.assign(:__modal_async_assign__, async_assign_field)
          |> Phoenix.Component.assign(:__lavash_module__, module_name)
          |> Phoenix.Component.assign(:__lavash_state__, optimistic_json)
          |> Phoenix.Component.assign(:__lavash_version__, version)
          |> Phoenix.Component.assign(:__lavash_animated__, unquote(animated_json))
          |> Phoenix.Component.assign(:__lavash_bindings__, bindings_json)

        ~H"""
        <div
          id={"lavash-#{@id}"}
          phx-hook="LavashOptimistic"
          data-lavash-component
          data-lavash-module={@__lavash_module__}
          data-lavash-state={@__lavash_state__}
          data-lavash-version={@__lavash_version__}
          data-lavash-animated={@__lavash_animated__}
          data-lavash-bindings={@__lavash_bindings__}
          class="contents"
        >
          <.modal_chrome
            id={@__modal_id__}
            module={@__modal_module__}
            open={@__modal_open__}
            open_field={@__modal_open_field__}
            async_assign={@__modal_async_assign__}
            myself={@myself}
            close_on_escape={@__modal_close_on_escape__}
            close_on_backdrop={@__modal_close_on_backdrop__}
            max_width={@__modal_max_width__}
          >
            <:loading>
              {@__modal_loading__.(assigns)}
            </:loading>
            <Lavash.Overlay.Modal.Helpers.modal_content
              assigns={assigns}
              async_assign={@__modal_async_assign__}
              render={@__modal_render__}
              loading={@__modal_loading__}
            />
          </.modal_chrome>
        </div>
        """
      end
    end
  end

  defp generate_flyover_render(module) do
    open_field = Spark.Dsl.Extension.get_persisted(module, :flyover_open_field) || :open
    slide_from = Spark.Dsl.Extension.get_persisted(module, :flyover_slide_from) || :right
    close_on_escape = Spark.Dsl.Extension.get_persisted(module, :flyover_close_on_escape) || true

    close_on_backdrop =
      Spark.Dsl.Extension.get_persisted(module, :flyover_close_on_backdrop) || true

    width = Spark.Dsl.Extension.get_persisted(module, :flyover_width) || :md
    height = Spark.Dsl.Extension.get_persisted(module, :flyover_height) || :md
    async_assign = Spark.Dsl.Extension.get_persisted(module, :flyover_async_assign)
    helpers_path = @flyover_helpers_path

    # Get animated fields config at compile time for JS consumption
    animated_fields = Spark.Dsl.Extension.get_persisted(module, :lavash_animated_fields) || []

    animated_json =
      animated_fields
      |> Enum.map(fn config ->
        %{
          field: to_string(config.field),
          phaseField: to_string(config.phase_field),
          async: config.async && to_string(config.async),
          preserveDom: config.preserve_dom,
          duration: config.duration,
          type: config.type && to_string(config.type)
        }
      end)
      |> Jason.encode!()

    quote do
      # Track helpers.ex so changes trigger recompilation of this module
      @external_resource unquote(helpers_path)
      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        import Lavash.Overlay.Flyover.Helpers

        open_field = unquote(open_field)
        open_value = Map.get(var!(assigns), open_field)

        # Get the render functions from the DSL at runtime
        render_fn = Spark.Dsl.Extension.get_persisted(__MODULE__, :flyover_render_template)
        loading_fn = Spark.Dsl.Extension.get_persisted(__MODULE__, :flyover_render_loading_template)
        async_assign_field = unquote(async_assign)

        # Default loading function
        default_loading_fn = &Lavash.Overlay.Flyover.Helpers.default_loading/1

        # Build flyover ID from component ID
        flyover_id = "#{Map.get(var!(assigns), :id, "flyover")}-flyover"

        # Build the on_close JS command for use in render functions
        on_close =
          Phoenix.LiveView.JS.dispatch("close-panel", to: "##{flyover_id}")
          |> Phoenix.LiveView.JS.push("close", target: var!(assigns).myself)

        # Build optimistic state for data attribute (passive, no hook)
        optimistic_state = Lavash.Component.Helpers.optimistic_state(__MODULE__, var!(assigns))
        module_name = inspect(__MODULE__)
        optimistic_json = Lavash.JSON.encode!(optimistic_state)

        # Get optimistic version from socket
        version = Lavash.Socket.optimistic_version(var!(assigns).socket)

        # Get client bindings for parent-to-child propagation
        client_bindings = Map.get(var!(assigns), :__lavash_client_bindings__) || %{}
        bindings_json = Lavash.JSON.encode!(client_bindings)

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:__flyover_id__, flyover_id)
          |> Phoenix.Component.assign(:__flyover_module__, __MODULE__)
          |> Phoenix.Component.assign(:on_close, on_close)
          |> Phoenix.Component.assign(:__flyover_open__, open_value)
          |> Phoenix.Component.assign(:__flyover_open_field__, unquote(open_field))
          |> Phoenix.Component.assign(:__flyover_slide_from__, unquote(slide_from))
          |> Phoenix.Component.assign(:__flyover_close_on_escape__, unquote(close_on_escape))
          |> Phoenix.Component.assign(:__flyover_close_on_backdrop__, unquote(close_on_backdrop))
          |> Phoenix.Component.assign(:__flyover_width__, unquote(width))
          |> Phoenix.Component.assign(:__flyover_height__, unquote(height))
          |> Phoenix.Component.assign(:__flyover_render__, render_fn)
          |> Phoenix.Component.assign(:__flyover_loading__, loading_fn || default_loading_fn)
          |> Phoenix.Component.assign(:__flyover_async_assign__, async_assign_field)
          |> Phoenix.Component.assign(:__lavash_module__, module_name)
          |> Phoenix.Component.assign(:__lavash_state__, optimistic_json)
          |> Phoenix.Component.assign(:__lavash_version__, version)
          |> Phoenix.Component.assign(:__lavash_animated__, unquote(animated_json))
          |> Phoenix.Component.assign(:__lavash_bindings__, bindings_json)

        ~H"""
        <div
          id={"lavash-#{@id}"}
          phx-hook="LavashOptimistic"
          data-lavash-component
          data-lavash-module={@__lavash_module__}
          data-lavash-state={@__lavash_state__}
          data-lavash-version={@__lavash_version__}
          data-lavash-animated={@__lavash_animated__}
          data-lavash-bindings={@__lavash_bindings__}
          class="contents"
        >
          <.flyover_chrome
            id={@__flyover_id__}
            module={@__flyover_module__}
            open={@__flyover_open__}
            open_field={@__flyover_open_field__}
            slide_from={@__flyover_slide_from__}
            async_assign={@__flyover_async_assign__}
            myself={@myself}
            close_on_escape={@__flyover_close_on_escape__}
            close_on_backdrop={@__flyover_close_on_backdrop__}
            width={@__flyover_width__}
            height={@__flyover_height__}
          >
            <:loading>
              {@__flyover_loading__.(assigns)}
            </:loading>
            <Lavash.Overlay.Flyover.Helpers.flyover_content
              assigns={assigns}
              async_assign={@__flyover_async_assign__}
              render={@__flyover_render__}
              loading={@__flyover_loading__}
            />
          </.flyover_chrome>
        </div>
        """
      end
    end
  end
end
