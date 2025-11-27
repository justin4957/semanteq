defmodule Semanteq.Session do
  @moduledoc """
  ETS-based session management for tracking generation history.

  This module provides session persistence across requests, allowing:
  - Tracking of prompts and results within a session
  - Session-scoped context for refinement operations
  - Configurable session TTL with automatic expiration
  - Memory-efficient storage using ETS

  ## Usage

      # Create a new session
      {:ok, session_id} = Semanteq.Session.create()

      # Add an entry to a session
      :ok = Semanteq.Session.add_entry(session_id, %{
        type: :generate,
        prompt: "Create a function...",
        result: %{gexpr: ...}
      })

      # Get session history
      {:ok, session} = Semanteq.Session.get(session_id)

      # List all sessions
      sessions = Semanteq.Session.list()

  ## Configuration

  Configure in config.exs:

      config :semanteq, :session,
        ttl_seconds: 3600,           # Session TTL (default: 1 hour)
        max_entries_per_session: 100, # Max entries per session
        cleanup_interval_ms: 60_000   # Cleanup interval (default: 1 minute)
  """

  use GenServer

  require Logger

  @table_name :semanteq_sessions
  @default_ttl_seconds 3600
  @default_max_entries 100
  @default_cleanup_interval_ms 60_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the session manager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new session and returns its ID.

  ## Options
    - `:metadata` - Optional metadata to store with the session

  ## Returns
    - `{:ok, session_id}` on success
  """
  def create(opts \\ []) do
    GenServer.call(__MODULE__, {:create, opts})
  end

  @doc """
  Gets a session by ID.

  ## Returns
    - `{:ok, session}` if found
    - `{:error, :not_found}` if session doesn't exist or has expired
  """
  def get(session_id) do
    GenServer.call(__MODULE__, {:get, session_id})
  end

  @doc """
  Adds an entry to a session's history.

  ## Parameters
    - session_id: The session ID
    - entry: A map containing the entry data (type, prompt, result, etc.)

  ## Returns
    - `:ok` on success
    - `{:error, :not_found}` if session doesn't exist
    - `{:error, :max_entries_reached}` if session has reached max entries
  """
  def add_entry(session_id, entry) do
    GenServer.call(__MODULE__, {:add_entry, session_id, entry})
  end

  @doc """
  Updates session metadata.

  ## Parameters
    - session_id: The session ID
    - metadata: New metadata to merge with existing

  ## Returns
    - `:ok` on success
    - `{:error, :not_found}` if session doesn't exist
  """
  def update_metadata(session_id, metadata) do
    GenServer.call(__MODULE__, {:update_metadata, session_id, metadata})
  end

  @doc """
  Refreshes the session's expiration time.

  ## Returns
    - `:ok` on success
    - `{:error, :not_found}` if session doesn't exist
  """
  def touch(session_id) do
    GenServer.call(__MODULE__, {:touch, session_id})
  end

  @doc """
  Deletes a session.

  ## Returns
    - `:ok` always (idempotent)
  """
  def delete(session_id) do
    GenServer.call(__MODULE__, {:delete, session_id})
  end

  @doc """
  Lists all active sessions.

  ## Options
    - `:include_entries` - Include full history (default: false)

  ## Returns
    - List of sessions
  """
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc """
  Clears all sessions.

  ## Returns
    - `:ok`
  """
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  @doc """
  Gets the session statistics.

  ## Returns
    - Map with session stats
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Returns the default session configuration.
  """
  def default_config do
    %{
      ttl_seconds: config()[:ttl_seconds] || @default_ttl_seconds,
      max_entries_per_session: config()[:max_entries_per_session] || @default_max_entries,
      cleanup_interval_ms: config()[:cleanup_interval_ms] || @default_cleanup_interval_ms
    }
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    # Schedule periodic cleanup
    cleanup_interval = config()[:cleanup_interval_ms] || @default_cleanup_interval_ms
    schedule_cleanup(cleanup_interval)

    Logger.info("Session manager started with TTL=#{ttl_seconds()}s")

    {:ok, %{cleanup_interval: cleanup_interval, stats: %{created: 0, expired: 0}}}
  end

  @impl true
  def handle_call({:create, opts}, _from, state) do
    session_id = generate_session_id()
    metadata = Keyword.get(opts, :metadata, %{})

    session = %{
      id: session_id,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      expires_at: calculate_expiration(),
      metadata: metadata,
      entries: []
    }

    :ets.insert(@table_name, {session_id, session})

    new_stats = Map.update!(state.stats, :created, &(&1 + 1))
    {:reply, {:ok, session_id}, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:get, session_id}, _from, state) do
    result =
      case :ets.lookup(@table_name, session_id) do
        [{^session_id, session}] ->
          if expired?(session) do
            :ets.delete(@table_name, session_id)
            {:error, :not_found}
          else
            {:ok, session}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:add_entry, session_id, entry}, _from, state) do
    result =
      case :ets.lookup(@table_name, session_id) do
        [{^session_id, session}] ->
          if expired?(session) do
            :ets.delete(@table_name, session_id)
            {:error, :not_found}
          else
            max_entries = config()[:max_entries_per_session] || @default_max_entries

            if length(session.entries) >= max_entries do
              {:error, :max_entries_reached}
            else
              timestamped_entry =
                entry
                |> Map.put(:timestamp, DateTime.utc_now())
                |> Map.put(:index, length(session.entries))

              updated_session = %{
                session
                | entries: session.entries ++ [timestamped_entry],
                  updated_at: DateTime.utc_now(),
                  expires_at: calculate_expiration()
              }

              :ets.insert(@table_name, {session_id, updated_session})
              :ok
            end
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_metadata, session_id, new_metadata}, _from, state) do
    result =
      case :ets.lookup(@table_name, session_id) do
        [{^session_id, session}] ->
          if expired?(session) do
            :ets.delete(@table_name, session_id)
            {:error, :not_found}
          else
            updated_session = %{
              session
              | metadata: Map.merge(session.metadata, new_metadata),
                updated_at: DateTime.utc_now()
            }

            :ets.insert(@table_name, {session_id, updated_session})
            :ok
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:touch, session_id}, _from, state) do
    result =
      case :ets.lookup(@table_name, session_id) do
        [{^session_id, session}] ->
          if expired?(session) do
            :ets.delete(@table_name, session_id)
            {:error, :not_found}
          else
            updated_session = %{
              session
              | updated_at: DateTime.utc_now(),
                expires_at: calculate_expiration()
            }

            :ets.insert(@table_name, {session_id, updated_session})
            :ok
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete, session_id}, _from, state) do
    :ets.delete(@table_name, session_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    include_entries = Keyword.get(opts, :include_entries, false)

    sessions =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, session} -> session end)
      |> Enum.reject(&expired?/1)
      |> Enum.map(fn session ->
        if include_entries do
          session
        else
          Map.put(session, :entry_count, length(session.entries))
          |> Map.delete(:entries)
        end
      end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:reply, sessions, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    active_count = :ets.info(@table_name, :size)

    stats = %{
      active_sessions: active_count,
      total_created: state.stats.created,
      total_expired: state.stats.expired,
      ttl_seconds: ttl_seconds(),
      max_entries_per_session: config()[:max_entries_per_session] || @default_max_entries
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    expired_count = cleanup_expired_sessions()

    new_stats = Map.update!(state.stats, :expired, &(&1 + expired_count))

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired sessions")
    end

    schedule_cleanup(state.cleanup_interval)
    {:noreply, %{state | stats: new_stats}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp config do
    Application.get_env(:semanteq, :session, [])
  end

  defp ttl_seconds do
    config()[:ttl_seconds] || @default_ttl_seconds
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp calculate_expiration do
    DateTime.utc_now() |> DateTime.add(ttl_seconds(), :second)
  end

  defp expired?(session) do
    DateTime.compare(DateTime.utc_now(), session.expires_at) == :gt
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp cleanup_expired_sessions do
    now = DateTime.utc_now()

    expired_ids =
      :ets.tab2list(@table_name)
      |> Enum.filter(fn {_id, session} ->
        DateTime.compare(now, session.expires_at) == :gt
      end)
      |> Enum.map(fn {id, _session} -> id end)

    Enum.each(expired_ids, &:ets.delete(@table_name, &1))

    length(expired_ids)
  end
end
