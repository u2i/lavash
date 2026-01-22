defmodule Lavash.Overlay.Flyover.RenderGenerator do
  @moduledoc """
  Generates the render/1 function for flyover components.

  This module is called by the component compiler when a flyover overlay
  is detected. It generates the complete render function with:
  - LavashOptimistic hook wrapper with state/bindings
  - Flyover chrome (backdrop, sliding panel, animations)
  - Content and loading slots
  """

  @behaviour Lavash.Overlay.RenderGenerator

  @helpers_path Path.expand("helpers.ex", __DIR__)

  @impl true
  def helpers_path, do: @helpers_path

  @impl true
  def generate(module) do
    open_field = Spark.Dsl.Extension.get_persisted(module, :flyover_open_field) || :open
    slide_from = Spark.Dsl.Extension.get_persisted(module, :flyover_slide_from) || :right
    close_on_escape = Spark.Dsl.Extension.get_persisted(module, :flyover_close_on_escape) || true
    close_on_backdrop = Spark.Dsl.Extension.get_persisted(module, :flyover_close_on_backdrop) || true
    width = Spark.Dsl.Extension.get_persisted(module, :flyover_width) || :md
    height = Spark.Dsl.Extension.get_persisted(module, :flyover_height) || :md
    async_assign = Spark.Dsl.Extension.get_persisted(module, :flyover_async_assign)
    helpers_path = @helpers_path

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

        # Build optimistic state for data attribute
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
