defmodule Managoat.Runtimes.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/managoat/managoat_runtimes"

  def project do
    [
      app: :managoat_runtimes,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "How a coding agent CLI (claude, codex, gemini, opencode) gets into a sandbox and comes up speaking ACP: the adapter pins, the file layout, the instructions file, the credential env vars, the skills tree, and the per-runtime workarounds with their deletion conditions.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [
        # What this suite measures on its own: 94.19% on the first
        # `mix test --cover` run after extraction (#1368), with the runtimes'
        # bootstraps, the adapter install and the skills mechanism driven
        # against a stubbed sandbox. Set a little under that so an added
        # error branch does not fail the gate on its own; raise it as the
        # library's own tests grow, never lower it.
        summary: [threshold: 90]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Tooling for the repository, not the package: docs for hexdocs.pm (built
      # by `mix hex.publish`), credo and dialyzer for CI. dialyxir is pinned to
      # the commit that added OTP 28 support; 1.4.7 crashes on OTP 28 warnings.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir,
       github: "jeremyjh/dialyxir",
       ref: "3553678f4d69281ac6db61034bcf35bcb30cfd78",
       only: [:dev, :test],
       runtime: false},
      # The sandbox the runtimes are provisioned into: exec, write_file,
      # spawn, the Handle and Retry. Both directions decisions/0037 pins.
      {:managoat_sandbox, "~> 0.1.0"},
      # Protocol.initialize_params/1 and default_client_capabilities/0, for
      # the params a host sends the adapter this library installed. Pinned to
      # 0.1.1 rather than 0.1.0 because `Quirks` names
      # `Usage.from_meta_quota/1` as a quirk's `implemented_by` and the
      # registry's guardrail asserts that function exists — an older
      # managoat_acp fails the suite rather than the billing.
      {:managoat_acp, "~> 0.1.1"},
      # The runtime config files (claude's .mcp.json and settings.json,
      # gemini's settings.json) are JSON.
      {:jason, "~> 1.2"},
      {:mimic, "~> 2.3", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      # priv/ carries the gemini session-store consolidation script, which
      # Gemini.SessionStore embeds at compile time.
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp dialyzer do
    [
      ignore_warnings: ".dialyzer_ignore.exs",
      # A fixed path so CI can cache the PLT across runs.
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
