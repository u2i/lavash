defmodule Lavash.Parity.UploadSink do
  @moduledoc """
  In-memory destination for the uploads parity suite.

  Real apps copy the upload to disk or S3. The parity test
  doesn't care WHERE the bytes land, just that the
  `consume_uploaded_entries/3` callback was invoked and received
  the right contents. So `record/2` writes filename → contents to
  ETS; the test reads back from there.
  """

  @table :lavash_parity_upload_sink

  @doc "Creates the ETS table. Idempotent."
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :set])
        :ok

      _ ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  @doc "Records the contents of a consumed upload."
  def record(client_name, contents) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {client_name, contents})
    end

    :ok
  end

  @doc "Reads a previously-recorded upload by filename."
  def get(client_name) do
    case :ets.lookup(@table, client_name) do
      [{^client_name, contents}] -> {:ok, contents}
      [] -> :error
    end
  end
end
