defmodule Managoat.Runtimes.Claude do
  @moduledoc """
  Anthropic Claude runtime — provisioning only.

  Turns speak ACP through the pinned `claude-agent-acp` adapter
  (`Managoat.Runtimes.ACP`); the CLI argv builder that used to live here went
  with the legacy spawn path. What remains is the half ADR 0014 deliberately
  kept: how credentials, skills and MCP servers get into the sandbox.

  The adapter runs on the Claude Agent SDK, which reads the same skills tree
  as the CLI (`/home/sprite/.claude/skills`, verified live 2026-08-10) and
  honours the same credential env vars.

  ## MCP servers are provisioned, not delivered over ACP (#837)

  ACP defines a session-scoped channel for MCP servers (`session/new`'s
  `mcpServers`), and `Managoat.ACP.Peer` sends the agent's servers
  there correctly (pinned by `peer_mcp_test.exs`). But `claude-agent-acp`
  0.66–0.70 never launched stdio servers passed that way — reproduced
  standalone, upstream bug [agentclientprotocol/claude-agent-acp#883]. On
  the 0.75.1 pin (2026-09-07) a stdio server passed only over `session/new`
  *does* reach the model, and a server named on both paths is registered
  once; `http`/`sse` entries over the session-scoped path are not yet
  measured, which is why this provisioning stays until they are.

  So `write_config/2` provisions the servers into the sandbox instead, as a
  project `.mcp.json` plus `enableAllProjectMcpServers` in
  `~/.claude/settings.json` — which the CLI loads via its `settingSources`.
  This path is verified working end-to-end (2026-08-19): the model calls
  `mcp__<server>__*` tools and gets results. It works on every provider (all
  share `HOME=/home/sprite`), and the `${VAR}` refs are already resolved
  because the caller hands us the substituted agent.

  When the upstream bug is fixed, the session-scoped path will start working
  too; at that point drop this provisioning to avoid double-registration
  (cf. the same lesson in `Managoat.Runtimes.Gemini`). Registered as
  `:claude_mcp_via_files` in `Managoat.Runtimes.Quirks`, which carries the
  re-probe procedure and is guarded by a test that fails if this function
  disappears without the entry.

  ## The model list is warmed at provisioning

  The adapter advertises whatever the Claude Code binary bundled in its SDK
  reports, and that binary has two model lists. The built-in one (`default`,
  `opus`, `sonnet`, `haiku`) is there on every start. The other — the org's
  "additional models", which is where Fable is — comes from a fetch the CLI
  makes *after* a session has started and caches in `~/.claude.json`
  (`additionalModelOptionsCache`) for the *next* launch. So the first session
  in a fresh sandbox never lists Fable, and `session/set_config_option` with
  `claude-fable-5-1` is refused there on every adapter version; the second
  session in the same sandbox lists it. Measured 2026-09-07 with a fresh
  `CLAUDE_CONFIG_DIR` per run, on adapters 0.66.0 and 0.75.1.

  `prepare_sandbox/3` therefore opens one throwaway ACP session through the
  pinned adapter (`initialize` + `session/new`, no prompt, no tokens) and
  waits for the cache to land — under three seconds measured — before the
  host's first real session. Best-effort: a cache that stays cold is logged
  and provisioning goes on, since only the additional models are affected.
  Registered as `:claude_model_list_warmup` in `Managoat.Runtimes.Quirks`.
  """

  @behaviour Managoat.Runtimes

  require Logger

  alias Managoat.Runtimes.Layout

  @runtime "claude"

  # Where `Managoat.Runtimes.ACP.install/3` symlinks the adapter, and where
  # the CLI keeps its per-user state (`CLAUDE_CONFIG_DIR` overrides HOME).
  @adapter_bin "/home/sprite/.local/bin/claude-agent-acp"

  # The project-scope config sits at the repo root the agent runs in, not
  # under the config directory — that is what makes it *project* scope.
  @mcp_config Path.join(Layout.cwd(@runtime), ".mcp.json")
  @settings Path.join(Layout.config_root(@runtime), "settings.json")

  @impl true
  def skills_root, do: Layout.skills_root(@runtime)

  @impl true
  def skills_sh_agent, do: Layout.skills_sh_agent(@runtime)

  @impl true
  def default_env(_agent, inference_credentials) do
    # OAuth token takes precedence — it bills against a Claude.ai
    # subscription (Pro/Team) instead of metered API usage. When set, we
    # do NOT also export ANTHROPIC_API_KEY: claude prefers the oauth
    # path, but mixing the two has caused observable surprises (auth
    # picked from the wrong env var, depending on CLI version), so we
    # pick exactly one here.
    oauth = Map.get(inference_credentials, :claude_code_oauth_token)
    api_key = Map.get(inference_credentials, :anthropic_api_key)

    cond do
      is_binary(oauth) and oauth != "" -> [{"CLAUDE_CODE_OAUTH_TOKEN", oauth}]
      is_binary(api_key) and api_key != "" -> [{"ANTHROPIC_API_KEY", api_key}]
      true -> []
    end
  end

  @doc """
  Provision the agent's MCP servers into the sandbox (see the moduledoc for
  why this, not the ACP session-scoped channel). No servers → nothing written.
  """
  @impl true
  def write_config(_handle, nil), do: :ok
  def write_config(_handle, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(handle, %{mcp_servers: mcp_servers}) when is_map(mcp_servers) do
    # Project-scope config the CLI reads via settingSources; `mcp_servers` is
    # already the Claude-Code shape (`%{name => %{"command"/"args"/"env"...}}`)
    # with `${VAR}` refs resolved by the caller.
    #
    # Both writes are idempotent, so a transport blip on a sprite that has
    # only just booted is retried rather than failing the provision: the
    # first filesystem call into a fresh sprite timed out once in prod and
    # took the whole conversation with it.
    mcp_json = Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)

    # Pre-approve the project's servers so the first turn does not stall on
    # an approval the sandbox has no human to answer. (Fountain's ACP peer
    # also auto-allows `session/request_permission`, but that only fires
    # mid-turn; pre-approval keeps the server connected from session start.)
    settings = Jason.encode!(%{"enableAllProjectMcpServers" => true}, pretty: true)

    with :ok <- write_retrying(handle, @mcp_config, mcp_json) do
      write_retrying(handle, @settings, settings)
    end
  end

  def write_config(_handle, _agent), do: :ok

  @doc """
  Warm the CLI's additional-models cache before the host's first session (see
  the moduledoc). Runs the pinned adapter once with no prompt, so it needs the
  credential the turn will use: with neither `ANTHROPIC_API_KEY` nor
  `CLAUDE_CODE_OAUTH_TOKEN` in `sprite_env` there is nothing to fetch with,
  and nothing is run.

  `:ok` whether the cache warmed or not — a cold cache costs the additional
  models only, and is logged. A sandbox that cannot run the script at all is
  `{:error, {:claude_model_list_warmup, reason}}`, like the siblings.
  """
  @impl true
  def prepare_sandbox(handle, _agent, sprite_env) do
    if credential?(sprite_env) do
      case Managoat.Sandbox.exec(handle, "bash", ["-lc", warmup_script()],
             env: sprite_env,
             timeout: 90_000
           ) do
        {:ok, out, 0} ->
          unless warmed?(out) do
            Logger.warning(
              "claude model list did not warm before the first session; " <>
                "the org's additional models (Fable) will not be selectable in it"
            )
          end

          :ok

        {:ok, out, code} ->
          Logger.warning(
            "claude model list warm-up exited #{code}: #{String.slice(to_string(out), 0, 500)}"
          )

          :ok

        {:error, reason} ->
          {:error, {:claude_model_list_warmup, reason}}
      end
    else
      :ok
    end
  end

  defp credential?(sprite_env) do
    Enum.any?(sprite_env, fn
      {k, v} when k in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] ->
        is_binary(v) and v != ""

      _ ->
        false
    end)
  end

  defp warmed?(out), do: out |> to_string() |> String.trim() |> String.ends_with?("warm")

  # One ACP session with no prompt, fed from the same block that polls for
  # the cache: closing stdin is what ends the adapter, and `timeout` bounds
  # it if a version ever ignores EOF. The 30s poll bound is generous against
  # the ~3s measured, and is also the whole cost of a credential the org
  # refuses (nothing to fetch, the poll runs out); the exec timeout sits
  # above both. Idempotent — a warm sandbox (a shared one on its second
  # conversation) exits before running anything.
  defp warmup_script do
    cwd = Layout.cwd(@runtime)

    init =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: 1,
          clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}}
        }
      })

    new =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 2,
        method: "session/new",
        params: %{cwd: cwd, mcpServers: []}
      })

    """
    set -u
    cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    if grep -q '"additionalModelOptionsCache"' "$cfg" 2>/dev/null; then
      echo warm
      exit 0
    fi
    mkdir -p #{cwd}
    cd #{cwd}
    {
      printf '%s\\n' '#{init}' '#{new}'
      i=0
      while [ "$i" -lt 60 ]; do
        if grep -q '"additionalModelOptionsCache"' "$cfg" 2>/dev/null; then break; fi
        sleep 0.5
        i=$((i + 1))
      done
    } 2>/dev/null | timeout 45 #{@adapter_bin} >/dev/null 2>&1
    if grep -q '"additionalModelOptionsCache"' "$cfg" 2>/dev/null; then
      echo warm
    else
      echo cold
    fi
    exit 0
    """
  end

  defp write_retrying(handle, path, body) do
    case Managoat.Sandbox.Retry.with_backoff(
           fn -> Managoat.Sandbox.write_file(handle, path, body) end,
           label: "claude config write #{path}"
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_config, path, reason}}
    end
  end

  @doc """
  Swaps `CLAUDE_CODE_OAUTH_TOKEN` for `ANTHROPIC_API_KEY` in an already-built
  env list — what a live turn asks for after the org has refused the OAuth
  token (#655). Left as-is (still carrying the doomed OAuth token) when no
  API key is on file: the caller decides what to tell the tenant when there
  is nothing to fall back to.

  Deliberately not folded into `default_env/2` as a "skip oauth" flag: that
  function runs at provisioning, before any turn has been attempted, so it
  has no way to know the token is bad. This is reached only after the specific
  ACP failure that says so.
  """
  @spec fall_back_to_api_key([{String.t(), String.t()}], %{atom() => String.t()}) ::
          [{String.t(), String.t()}]
  def fall_back_to_api_key(env, inference_credentials) do
    case Map.get(inference_credentials, :anthropic_api_key) do
      key when is_binary(key) and key != "" ->
        env
        |> Enum.reject(fn {k, _v} -> k == "CLAUDE_CODE_OAUTH_TOKEN" end)
        |> List.keystore("ANTHROPIC_API_KEY", 0, {"ANTHROPIC_API_KEY", key})

      _ ->
        env
    end
  end
end
