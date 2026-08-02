# Dependency Audit — ElxMCP
**Date:** 2026-08-02
**Score:** 85

## Summary

Re-verified dependency health against prior baseline (86/B, same day). `mix hex.audit` is clean; all Hex top-level deps report **Up-to-date**; `mix deps.audit` / `mix_audit` still absent. Core stack (Phoenix 1.8.9, LiveView 1.2.8, Ecto SQL 3.14.0, Bandit 1.12.4, anubis_mcp 1.14.0) is current and locked. Residual risk is process/hygiene: no CVE-class advisory scan, unused mail/HTTP stack (`swoosh`/`req`), loose `postgrex` constraint, and LGPL Combined Work packaging depth for Anubis. No P1 security findings in deps.

## Score breakdown (hex.audit 40, deps.audit 20, outdated 20, unused 10, pinning 10)

| Area | Points | Max | Notes |
|------|--------|-----|--------|
| hex.audit | 40 | 40 | `No retired or security advisory packages found` |
| deps.audit | 10 | 20 | Task missing; `mix_audit` not in deps; only retired-package coverage via `hex.audit` in precommit |
| outdated | 20 | 20 | `mix hex.outdated`: all 20 Hex top-level deps Up-to-date |
| unused | 6 | 10 | `swoosh` + `req` scaffold only (no deliver / no `Req.` in `lib/`) |
| pinning | 9 | 10 | Mostly `~>`; `postgrex ">= 0.0.0"` unbounded; git asset tags locked by SHA |
| **Total** | **85** | **100** | |

Delta vs prior 86/B: −1 for stricter scoring of missing CVE-class audit (still no tool after re-audit).

## Issues found P1/P2/P3

### P1
*(none)*

### P2

1. **No CVE-class dependency audit (`mix deps.audit` / `mix_audit`)**
   - `mix deps.audit` → task not found.
   - No `mix_audit` (or equivalent) in `mix.exs` deps or aliases.
   - `precommit` runs `cmd mix hex.audit` only → retired Hex packages, not GitHub Advisory / OSV for BEAM graph.
   - **Remediation:** add `{:mix_audit, "~> 2.1", only: :dev, runtime: false}` (or current) and run `mix deps.audit` in precommit/CI; fail on known advisories.

2. **LGPL Combined Work packaging incomplete for binary redistribution**
   - `anubis_mcp` 1.14.0 is **LGPL-3.0** (core MCP path).
   - **Present:** root `NOTICE` (LGPL notice + replace/source pointers), `LICENSE` MIT note, README “Licenças de dependências”.
   - **Missing:** vendored full GPL-3.0 + LGPL-3.0 texts; release checklist for Combined Work materials; rebuild/relink steps beyond Hex/GitHub replace.
   - Risk is distribution/legal for binary/firmware ships, not runtime correctness.
   - **Remediation:** vendor license texts under e.g. `licenses/`; document binary release pack if you ship releases.

### P3

3. **Unused production deps: `swoosh` + `req`**
   | Dep | Constraint | Lock | App use |
   |-----|------------|------|---------|
   | `swoosh` | `~> 1.16` | 1.27.0 | `ElxMcp.Mailer` + dev `/mailbox` only; **no** `deliver` paths |
   | `req` | `~> 0.5` | 0.7.2 | **No** `Req.` in `lib/`; only `Swoosh.ApiClient.Req` in `config/prod.exs` |

   Both sit on the default prod compile graph for a read-only MCP server. Drop until email is real, or document intentional scaffold.

4. **Constraint hygiene**
   | Dep | Constraint | Issue |
   |-----|------------|--------|
   | `postgrex` | `">= 0.0.0"` | No upper bound (lock 0.22.3); prefer `~> 0.19` or `~> 0.22` |
   | `lazy_html` | `">= 0.1.0"` | test-only; loose but lower risk |
   | `dns_cluster` | `"~> 0.2.0"` | Patch-only (intentional narrow) |
   | `phoenix_live_view` | `"~> 1.2.0"` | Patch-only within 1.2 |
   | `anubis_mcp` → `peri` | exact `0.9.0` (transitive) | Cannot float without Anubis release |

5. **Git-sourced asset deps outside Hex audit surface**
   - `heroicons` @ tag `v2.2.0` (lock SHA `0435d4ca364a…`)
   - `daisyui` @ tag `v5.5.20` (lock SHA `22ecff57f2c3…`)
   - Integrity depends on `mix.lock` commits; tags can move if force-pushed (lock protects re-get of same lockfile).
   - Policy note: `daisyui` is wired in `assets/css/app.css` while `Agents.md` discourages daisyUI for custom UI — design debt, not a CVE.

6. **Prod graph includes dev-oriented package**
   - `phoenix_live_dashboard` is full-env; routes gated by `:dev_routes`. Optional `only: :dev` if prod never enables dashboard.

## Dependency inventory (brief)

### Top-level (`mix.exs` → `mix.lock`)

| Package | Constraint | Locked | Env / notes |
|---------|------------|--------|-------------|
| phoenix | `~> 1.8.9` | 1.8.9 | MIT |
| phoenix_ecto | `~> 4.5` | 4.7.0 | |
| ecto_sql | `~> 3.13` | 3.14.0 | Apache-2.0 |
| postgrex | `>= 0.0.0` | 0.22.3 | Apache-2.0; loose pin |
| phoenix_html | `~> 4.1` | 4.3.0 | |
| phoenix_live_reload | `~> 1.2` | 1.7.0 | dev only |
| phoenix_live_view | `~> 1.2.0` | 1.2.8 | |
| lazy_html | `>= 0.1.0` | 0.1.12 | test only |
| phoenix_live_dashboard | `~> 0.8.3` | 0.8.7 | |
| esbuild | `~> 0.10` | 0.10.0 | runtime: dev |
| tailwind | `~> 0.5` | 0.5.1 | runtime: dev |
| heroicons | git tag v2.2.0 | 0435d4ca… | app: false |
| daisyui | git tag v5.5.20 | 22ecff57… | app: false |
| swoosh | `~> 1.16` | 1.27.0 | MIT; scaffold only |
| req | `~> 0.5` | 0.7.2 | Apache-2.0; scaffold/Swoosh client only |
| telemetry_metrics | `~> 1.0` | 1.1.0 | |
| telemetry_poller | `~> 1.0` | 1.3.0 | |
| gettext | `~> 1.0` | 1.0.2 | |
| jason | `~> 1.2` | 1.4.5 | |
| dns_cluster | `~> 0.2.0` | 0.2.0 | |
| bandit | `~> 1.5` | 1.12.4 | MIT |
| anubis_mcp | `~> 1.14.0` | 1.14.0 | **LGPL-3.0** |

**Lock total:** 46 packages (22 top-level + 24 transitive).

### Notable transitives

| Package | Version | Via | Note |
|---------|---------|-----|------|
| peri | 0.9.0 (exact) | anubis_mcp | MIT; fixed by Anubis |
| finch / mint / nimble_* | current | anubis_mcp, req | HTTP stack |
| plug / plug_crypto | 1.20.3 / 2.2.0 | phoenix, anubis | shared |
| thousand_island | 1.5.0 | bandit | |
| ecto | 3.14.1 | ecto_sql / peri | |
| idna | 7.1.0 | mint | MIT |

### License notes

- App: **MIT** (`LICENSE`) + third-party pointer to `NOTICE`.
- `NOTICE` documents **anubis_mcp LGPL-3.0** with source/replace language — adequate for source/SaaS notice path.
- Other major Hex licenses sampled: Phoenix/Bandit/Swoosh MIT; Req/Postgrex/Ecto SQL Apache-2.0; peri MIT.

## Clean areas (one line)

`hex.audit` clean; all Hex deps current; Elixir `~> 1.18` floor; Anubis LGPL disclosed in NOTICE/LICENSE/README; precommit gates retired packages; MCP/core Phoenix stack actively used and locked.

## Commands run (this audit)

```
mix hex.audit          # clean (exit 0)
mix hex.outdated       # all Up-to-date (exit 0)
mix deps.audit         # task not found (exit 1)
mix deps.tree          # inspected
```

## Recommended actions (priority)

1. Add `mix_audit` + `deps.audit` to precommit/CI (complements `hex.audit`).
2. Vendor full GPL+LGPL texts if binary Combined Work ships with Anubis.
3. Remove or quarantine unused `swoosh`/`req` until email is productized.
4. Tighten `postgrex` to `~> 0.22` (or project policy range).
5. Keep git lock SHAs; resolve daisyUI vs `Agents.md` policy when touching UI.
