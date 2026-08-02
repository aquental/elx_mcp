# Dependencies audit — ElxMCP

**Date:** 2026-08-01  
**Scope:** `mix.exs`, `mix.lock`, direct usage under `lib/` / `config/` / `assets/`  
**Pulse (given):** `hex.audit` clean; `hex.outdated` all current (incl. `anubis_mcp` 1.14.0); `deps.audit` not installed  

## Score: **72 / 100** (Dependencies)

No Hex security/retired advisories and no outdated Hex packages. Score held back by LGPL compliance readiness, constraint hygiene, unused mail/HTTP stack, and missing continuous audit tooling.

---

## Issues only

### 1. [HIGH] `anubis_mcp` is LGPL-3.0 — compliance not documented

| | |
|---|---|
| **Package** | `anubis_mcp` 1.14.0 (direct, core MCP path) |
| **License** | LGPL-3.0 (`deps/anubis_mcp` package + LICENSE) |
| **Usage** | `ElxMcp.MCP.Server`, tools/resources, `Anubis.Server.Transport.StreamableHTTP.Plug` at `/mcp` |

**Implications (Combined Work / BEAM):**

- App loads Anubis modules into the same BEAM release → treated as a **Combined Work** under LGPLv3 §4 (not a loose HTTP client).
- Distributors must, at minimum:
  1. Give **prominent notice** that the Library is used and is LGPL-3.0.
  2. Accompany distribution with **GNU GPL + LGPL** license texts.
  3. Enable recipients to **modify/replace** the Library (typically convey Minimal Corresponding Source + Corresponding Application Code suitable for recombine/relink — BEAM has no clean “shared library” 4d1 path).
  4. Provide **Installation Information** when §6 GPL would require it (e.g. locked devices / signed firmware scenarios).
- Optional Anubis deps (`gun`, `jose`, `redix`) not pulled; still irrelevant to license of the linked library itself.
- Transitive `peri` 0.9.0 is MIT — no copyleft stack beyond Anubis.

**Gaps observed:**

- No root `LICENSE` / `NOTICE` for ElxMCP.
- README/spec do not disclose LGPL dependency or redistribution obligations.
- Shipping a proprietary binary release without the above is a **legal risk**, not a runtime bug.

**Remediation:** Legal review if product is closed-source/SaaS-distributed; add NOTICE + ship LGPL/GPL texts; document how users rebuild with a patched Anubis; or evaluate MIT/Apache MCP alternatives if LGPL is unacceptable.

---

### 2. [MEDIUM] Elixir version pin conflicts with `anubis_mcp`

| Project | Constraint |
|---------|------------|
| `mix.exs` / README | `elixir: "~> 1.17"` |
| `anubis_mcp` Hex meta | `elixir: "~> 1.18"` |

On Elixir 1.17, dependency metadata and CI matrices can disagree with the declared app floor. Raise app/docs to `~> 1.18` (or pin CI to 1.18+) so the floor matches the critical path dependency.

---

### 3. [MEDIUM] Continuous dependency audit tooling missing

- `deps.audit` / `mix_audit` **not installed** (given).
- `precommit` runs `deps.unlock --unused` but no CVE/advisory gate in CI aliases.
- `hex.audit` is manual; no locked check in `mix.exs` aliases.

**Remediation:** Add `mix_audit` (or equivalent) to `deps` + `precommit`/CI; fail on known advisories.

---

### 4. [LOW–MED] Unused production deps: `swoosh` + `req`

| Dep | mix.exs | Actual app use |
|-----|---------|----------------|
| `swoosh` | `~> 1.16` (all envs) | Only `ElxMcp.Mailer` scaffold + dev mailbox route; **no** `deliver` / email flows |
| `req` | `~> 0.5` (all envs) | No `Req.` calls in `lib/`; prod config only: `Swoosh.ApiClient.Req` |

Still compiled/started surface for a read-only MCP server. Either implement mail or drop until needed (`only: :dev` is insufficient if Mailer stays in app); if keeping for future mail, document that intent.

---

### 5. [LOW] Open / inconsistent version pins

| Dep | Pin | Issue |
|-----|-----|--------|
| `postgrex` | `">= 0.0.0"` | No upper bound; lock holds `0.22.3` today but `mix.exs` allows any future major |
| `dns_cluster` | `"~> 0.2.0"` | Unusually tight (patch-only) vs peers |
| `phoenix_live_view` | `"~> 1.2.0"` | Patch-only within 1.2; intentional but inconsistent with broader `~> 1.x` style |
| `anubis_mcp` → `peri` | exact `"0.9.0"` (transitive) | Cannot float Peri without Anubis release |

**Remediation:** Prefer `{:postgrex, "~> 0.19"}` (or current minor); align `dns_cluster` / LV ranges with upgrade policy.

---

### 6. [LOW] Git-sourced asset deps (supply-chain class)

```elixir
{:heroicons, github: "tailwindlabs/heroicons", tag: "v2.2.0", ...}
{:daisyui, github: "saadeghi/daisyui", tag: "v5.5.20", ...}
```

- Not Hex-audited; integrity relies on `mix.lock` commit SHAs (present — good).
- Tags can move if force-pushed (lock SHA still protects re-gets of same lock).
- `daisyui` conflicts with project style rule in `Agents.md` (“Never … daisyUI”) but is wired in `assets/css/app.css` — policy debt, not a CVE.

---

### 7. [INFO] Prod graph includes dev-oriented packages

- `phoenix_live_dashboard` is a full-env dep; routes gated by `:dev_routes` only. Not exposed in prod if config is correct, but still in the release tree.
- Optional tighten: `only: :dev` for LiveDashboard if prod never enables it.

---

## Explicit non-issues (out of score deductions)

- Hex retired / security advisories: **none** (given).
- Hex outdated: **none** (given).
- Core stack (Phoenix 1.8.9, LV 1.2.8, Ecto 3.14.x, Bandit 1.12.4, anubis 1.14.0) locked and current.
- MCP stack actively used (not dead weight).
- `lazy_html` correctly `only: :test` (LiveViewTest support).
- No GPL-only direct deps besides LGPL library above.

---

## Direct deps license snapshot (for compliance tracking)

| Direct dep | License (Hex/meta) |
|------------|--------------------|
| phoenix, phoenix_html, phoenix_live_view, phoenix_live_dashboard, phoenix_ecto, bandit, dns_cluster, esbuild, tailwind, swoosh | MIT |
| ecto_sql, postgrex, gettext, jason, req, telemetry_metrics, telemetry_poller, lazy_html | Apache-2.0 |
| **anubis_mcp** | **LGPL-3.0** |
| heroicons / daisyui (git) | upstream MIT-class (not Hex-licensed in lock) |

---

## Recommended actions (priority)

1. Document + implement LGPLv3 Combined Work obligations for `anubis_mcp`, or replace the library.
2. Bump Elixir floor to `~> 1.18` to match Anubis.
3. Add `mix_audit` (or `deps.audit`) to precommit/CI.
4. Remove or quarantine unused `swoosh`/`req` until email is real.
5. Replace `postgrex ">= 0.0.0"` with a caret/`~>` pin.
