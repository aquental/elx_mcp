# Dependency Audit — ElxMCP
**Date:** 2026-08-02 (re-run)
**Score:** 85 / 100

## Score breakdown

| Area | Points | Max | Notes |
|------|--------|-----|--------|
| hex.audit (vulns/retired) | 40 | 40 | Clean: no retired or security advisory packages |
| deps.audit (CVE-class) | 10 | 20 | `mix deps.audit` missing; no `mix_audit` in deps |
| outdated majors | 20 | 20 | All 20 Hex top-level deps Up-to-date |
| unused | 6 | 10 | `swoosh` + `req` scaffold only (no real use in `lib/`) |
| pinning | 9 | 10 | Mostly `~>`; `postgrex ">= 0.0.0"` unbounded |
| **Total** | **85** | **100** | |

## Issues only

### P1
*(none)*

### P2

1. **No CVE-class dependency audit**
   - `mix deps.audit` → task not found.
   - `mix_audit` (or equivalent) not in `mix.exs`.
   - `precommit` runs `cmd mix hex.audit` only (retired Hex packages / Hex advisories surface), not full OSV/GitHub Advisory graph scan for transitive BEAM deps.
   - **Remediation:** `{:mix_audit, "~> 2.1", only: :dev, runtime: false}` + `mix deps.audit` in precommit/CI.

2. **LGPL Combined Work packaging incomplete for binary redistribution**
   - `anubis_mcp` **1.14.0** is **LGPL-3.0** (core MCP path; confirmed in package metadata).
   - **Present:** root `NOTICE` (LGPL notice + Hex/GitHub source + replace language), `LICENSE` MIT third-party note, README license section.
   - **Missing:** vendored full GPL-3.0 + LGPL-3.0 texts under e.g. `licenses/`; release checklist for Combined Work materials if shipping binary/firmware releases (rebuild/relink beyond Hex replace).
   - Risk is distribution/legal for binary ships, not runtime correctness.
   - **Remediation:** vendor license texts; document binary release pack when applicable.

### P3

3. **Unused production deps: `swoosh` + `req`**

   | Dep | Constraint | Lock | App use |
   |-----|------------|------|---------|
   | `swoosh` | `~> 1.16` | 1.27.0 | `ElxMcp.Mailer` + dev `/mailbox` only; **no** `deliver` paths |
   | `req` | `~> 0.5` | 0.7.2 | **No** `Req.` in `lib/`; only `Swoosh.ApiClient.Req` in `config/prod.exs` |

   Both remain on the default prod compile graph for a read-only MCP server. Drop until email is real, or document intentional scaffold.

4. **Constraint hygiene**

   | Dep | Constraint | Issue |
   |-----|------------|--------|
   | `postgrex` | `">= 0.0.0"` | No upper bound (lock 0.22.3); prefer `~> 0.22` or `~> 0.19` |
   | `lazy_html` | `">= 0.1.0"` | test-only; loose but lower risk |
   | `dns_cluster` | `"~> 0.2.0"` | Patch-only (intentional narrow) |
   | `phoenix_live_view` | `"~> 1.2.0"` | Patch-only within 1.2 |
   | `anubis_mcp` → `peri` | exact `0.9.0` (transitive) | Cannot float without Anubis release |

5. **Git-sourced asset deps outside Hex audit surface**
   - `heroicons` @ tag `v2.2.0` (lock SHA)
   - `daisyui` @ tag `v5.5.20` (lock SHA)
   - Integrity depends on `mix.lock` commits; tags can move if force-pushed (lock protects re-get of same lockfile).
   - Policy note: `daisyui` is wired in assets while `Agents.md` discourages daisyUI for custom UI — design debt, not a CVE.

6. **Prod graph includes dev-oriented package**
   - `phoenix_live_dashboard` is full-env; routes gated by `:dev_routes`. Optional `only: :dev` if prod never enables dashboard.

## Recommended actions

1. Add `mix_audit` + `deps.audit` to precommit/CI.
2. Vendor full GPL+LGPL texts if binary Combined Work ships with Anubis.
3. Remove or quarantine unused `swoosh`/`req` until email is productized.
4. Tighten `postgrex` to `~> 0.22`.
5. Keep git lock SHAs; resolve daisyUI vs Agents.md policy when touching UI.

## Clean areas (one line each)

- `mix hex.audit`: no retired or security advisory packages.
- `mix hex.outdated`: all Hex top-level deps Up-to-date (no outdated majors).
- Core stack locked current: Phoenix 1.8.9, LV 1.2.8, ecto_sql 3.14.0, bandit 1.12.4, anubis_mcp 1.14.0.
- Anubis LGPL disclosed in NOTICE / LICENSE / README.
- Elixir floor `~> 1.18` matches Anubis requirement.
- precommit already gates `hex.audit` + `deps.unlock --unused`.

## Commands run

```
mix hex.audit          # clean (exit 0)
mix hex.outdated       # all Up-to-date
mix deps.audit         # task not found
mix deps.tree --format pretty | head
# + mix.exs / mix.lock / NOTICE / lib grep for Swoosh/Req
```

## Inventory snapshot (top-level → lock)

| Package | Constraint | Locked | Notes |
|---------|------------|--------|-------|
| phoenix | `~> 1.8.9` | 1.8.9 | MIT |
| phoenix_ecto | `~> 4.5` | 4.7.0 | |
| ecto_sql | `~> 3.13` | 3.14.0 | Apache-2.0 |
| postgrex | `>= 0.0.0` | 0.22.3 | **loose pin** |
| phoenix_html | `~> 4.1` | 4.3.0 | |
| phoenix_live_reload | `~> 1.2` | 1.7.0 | dev only |
| phoenix_live_view | `~> 1.2.0` | 1.2.8 | |
| lazy_html | `>= 0.1.0` | 0.1.12 | test only |
| phoenix_live_dashboard | `~> 0.8.3` | 0.8.7 | full-env |
| esbuild / tailwind | `~> 0.10` / `~> 0.5` | 0.10.0 / 0.5.1 | runtime: dev |
| heroicons / daisyui | git tags | lock SHA | app: false |
| swoosh | `~> 1.16` | 1.27.0 | **unused** (scaffold) |
| req | `~> 0.5` | 0.7.2 | **unused** (scaffold) |
| bandit | `~> 1.5` | 1.12.4 | MIT |
| anubis_mcp | `~> 1.14.0` | 1.14.0 | **LGPL-3.0** |
| others (jason, gettext, telemetry_*, dns_cluster) | `~>` | current | Up-to-date |

**Lock total:** 46 packages.
