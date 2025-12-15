defmodule Lavash.LiveView.Compiler do
  @moduledoc """
  Compiles the Lavash DSL into LiveView callbacks.
  """

  @doc """
  Expands derived form declarations into derived field structs.
  """
  def expand_derived(%Lavash.Derived.Form{} = form) do
    params_field = form.params || :"#{form.name}_params"
    load_field = form.load

    depends_on =
      if load_field do
        [load_field, params_field]
      else
        [params_field]
      end

    compute = fn deps ->
      params = Map.get(deps, params_field, %{})
      record = if load_field, do: Map.get(deps, load_field), else: nil

      Lavash.Form.for_resource(form.resource, record, params,
        create: form.create,
        update: form.update
      )
    end

    %Lavash.Derived.Field{
      name: form.name,
      depends_on: depends_on,
      async: false,
      compute: compute
    }
  end

  def expand_derived(field), do: field

  defmacro __before_compile__(env) do
    has_on_mount = Module.defines?(env.module, {:on_mount, 1})
    has_render = Module.defines?(env.module, {:render, 1})

    mount_callback =
      if has_on_mount do
        quote do
          @impl Phoenix.LiveView
          def mount(params, session, socket) do
            {:ok, socket} = Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
            on_mount(socket)
          end
        end
      else
        quote do
          @impl Phoenix.LiveView
          def mount(params, session, socket) do
            Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
          end
        end
      end

    quote do
      unquote(mount_callback)

      @impl Phoenix.LiveView
      def handle_params(params, uri, socket) do
        Lavash.LiveView.Runtime.handle_params(__MODULE__, params, uri, socket)
      end

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) do
        Lavash.LiveView.Runtime.handle_event(__MODULE__, event, params, socket)
      end

      @impl Phoenix.LiveView
      def handle_info(msg, socket) do
        Lavash.LiveView.Runtime.handle_info(__MODULE__, msg, socket)
      end

      # Introspection functions
      def __lavash__(:url_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :url])
      end

      def __lavash__(:ephemeral_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :ephemeral])
      end

      def __lavash__(:socket_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :socket])
      end

      def __lavash__(:form_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state])
        |> Enum.filter(&is_struct(&1, Lavash.State.FormField))
      end

      def __lavash__(:derived_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derived])
        |> Enum.map(&Lavash.LiveView.Compiler.expand_derived/1)
      end

      def __lavash__(:assigns) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:assigns])
      end

      def __lavash__(:actions) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
      end
    end
  end
end
