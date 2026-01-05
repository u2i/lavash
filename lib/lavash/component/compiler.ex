defmodule Lavash.Component.Compiler do
  @moduledoc """
  Compiles the Lavash Component DSL into LiveComponent callbacks.
  """

  # Track helpers.ex as an external resource so changes trigger recompilation
  # of all modules that use the modal DSL. Path.expand with __DIR__ gives us
  # the absolute path at compile time of this module (in lavash's lib dir).
  @helpers_path Path.expand("../overlay/modal/helpers.ex", __DIR__)

  defmacro __before_compile__(env) do
    modal_render = Spark.Dsl.Extension.get_persisted(env.module, :modal_render_template)

    # Get optimistic colocated data if available (persisted by ColocatedTransformer)
    # Escape immediately to avoid "tried to unquote invalid AST" errors during incremental compilation
    optimistic_colocated_data =
      case Spark.Dsl.Extension.get_persisted(env.module, :lavash_optimistic_colocated_data) do
        nil -> nil
        data -> Macro.escape(data)
      end

    render_function =
      if modal_render do
        generate_modal_render(env.module)
      else
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
    helpers_path = @helpers_path

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

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:__modal_id__, modal_id)
          |> Phoenix.Component.assign(:on_close, on_close)
          |> Phoenix.Component.assign(:__modal_open__, open_value)
          |> Phoenix.Component.assign(:__modal_open_field__, unquote(open_field))
          |> Phoenix.Component.assign(:__modal_close_on_escape__, unquote(close_on_escape))
          |> Phoenix.Component.assign(:__modal_close_on_backdrop__, unquote(close_on_backdrop))
          |> Phoenix.Component.assign(:__modal_max_width__, unquote(max_width))
          |> Phoenix.Component.assign(:__modal_render__, render_fn)
          |> Phoenix.Component.assign(:__modal_loading__, loading_fn || default_loading_fn)
          |> Phoenix.Component.assign(:__modal_async_assign__, async_assign_field)

        ~H"""
        <div class="contents">
          <.modal_chrome
            id={@__modal_id__}
            open={@__modal_open__}
            open_field={@__modal_open_field__}
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
end
