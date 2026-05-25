defmodule Lavash.Overlay.Modal.RenderGenerator do
  @moduledoc """
  Generates the render/1 function for modal components.

  This module is called by the component compiler when a modal overlay
  is detected. It generates the complete render function with:
  - LavashOptimistic hook wrapper with state/bindings
  - Modal chrome (backdrop, panel, animations)
  - Content and loading slots
  """

  @behaviour Lavash.Overlay.RenderGenerator

  @helpers_path Path.expand("helpers.ex", __DIR__)

  @impl true
  def helpers_path, do: @helpers_path

  # Generate code for render function based on template type.
  # Uses pre-tokenized tokens when available for consistent attribute injection.
  defp generate_render_fn_code({:render_ast, escaped_fn}, field, _module, dsl_state, env) do
    # Only use pre-tokenized tokens for the main render template.
    # Loading templates have different content — pre-tokens are for the main render only.
    use_pre_tokens = field == :modal_render_template

    pre_tokens =
      use_pre_tokens && Spark.Dsl.Transformer.get_persisted(dsl_state, :lavash_template_tokens)

    template_source =
      use_pre_tokens && Spark.Dsl.Transformer.get_persisted(dsl_state, :lavash_template_source)

    if pre_tokens && template_source do
      metadata =
        Lavash.Component.Transformers.CompileComponent.build_token_transformer_metadata_from_dsl(
          env,
          dsl_state
        )

      compiled =
        Lavash.TagEngine.compile_from_tokens(pre_tokens,
          file: env.file,
          line: 1,
          caller: env,
          source: template_source,
          tag_handler: Phoenix.LiveView.HTMLEngine,
          token_transformer: Lavash.Template.TokenTransformer,
          lavash_metadata: metadata
        )

      # Wrap compiled AST in a function for runtime invocation
      quote do
        fn var!(assigns) -> unquote(compiled) end
      end
    else
      # Fallback: use escaped fn with ~L sigil expansion
      escaped_fn
    end
  end

  defp generate_render_fn_code(_other, field, _module, _dsl_state, _env) do
    quote do
      Spark.Dsl.Extension.get_persisted(__MODULE__, unquote(field))
    end
  end

  @impl true
  def generate(module, dsl_state) do
    alias Spark.Dsl.Transformer
    env = Transformer.get_persisted(dsl_state, :env)
    open_field = Transformer.get_persisted(dsl_state, :modal_open_field) || :open
    close_on_escape = Transformer.get_persisted(dsl_state, :modal_close_on_escape) || true
    close_on_backdrop = Transformer.get_persisted(dsl_state, :modal_close_on_backdrop) || true
    max_width = Transformer.get_persisted(dsl_state, :modal_max_width) || :md
    async_assign = Transformer.get_persisted(dsl_state, :modal_async_assign)
    helpers_path = @helpers_path

    # Get render templates - may be {:render_ast, escaped_fn} or direct functions
    render_template = Transformer.get_persisted(dsl_state, :modal_render_template)
    loading_template = Transformer.get_persisted(dsl_state, :modal_render_loading_template)

    # Get animated fields config at compile time for JS consumption
    animated_fields = Transformer.get_persisted(dsl_state, :lavash_animated_fields) || []

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

    # Generate code to define render_fn based on template type
    # For render AST, we compile in the module's context
    render_fn_code =
      generate_render_fn_code(render_template, :modal_render_template, module, dsl_state, env)

    loading_fn_code =
      generate_render_fn_code(
        loading_template,
        :modal_render_loading_template,
        module,
        dsl_state,
        env
      )

    quote do
      # Track helpers.ex so changes trigger recompilation of this module
      @external_resource unquote(helpers_path)

      @impl Phoenix.LiveComponent
      def render(var!(assigns)) do
        import Lavash.Overlay.Modal.Helpers

        open_field = unquote(open_field)
        open_value = Map.get(var!(assigns), open_field)

        # Define render functions - either from unquoted AST or runtime lookup
        render_fn = unquote(render_fn_code)
        loading_fn = unquote(loading_fn_code)
        async_assign_field = unquote(async_assign)

        # Default loading function
        default_loading_fn = &Lavash.Overlay.Modal.Helpers.default_loading/1

        # Build modal ID from component ID
        modal_id = "#{Map.get(var!(assigns), :id, "modal")}-modal"

        # Build the on_close JS command for use in render functions
        on_close =
          Phoenix.LiveView.JS.dispatch("close-panel", to: "##{modal_id}")
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

        # Server-known phase from the auto-injected `{open_field}_phase` state.
        # This lags the client's phase machine — server only knows idle vs
        # whatever the client last synced. Useful as an end-of-transition
        # observable for tests; intermediate animation frames live on the
        # client and need DOM-shape probes (opacity, hidden, etc).
        phase_field = :"#{unquote(open_field)}_phase"
        modal_phase = Map.get(var!(assigns), phase_field) || "idle"

        var!(assigns) =
          var!(assigns)
          |> Phoenix.Component.assign(:__modal_id__, modal_id)
          |> Phoenix.Component.assign(:__modal_module__, __MODULE__)
          |> Phoenix.Component.assign(:on_close, on_close)
          |> Phoenix.Component.assign(:__modal_open__, open_value)
          |> Phoenix.Component.assign(:__modal_phase__, modal_phase)
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
          data-modal-phase={@__modal_phase__}
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
end
