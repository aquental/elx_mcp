# Scratchpad: ElxMCP P1 Residual

## Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Research agents | Skipped | Planning from audit findings (skill Iron Law #7) |
| Depth | standard | 7 P1s, multi-context, no new product domain |
| Rate limit | Application owns ETS | Minimal OTP; fixes table lifetime |
| Session bind | **Path A** | Plug before Anubis can intercept DELETE/GET/POST |
| Search | exact → prefix → title (trgm) | Keep hard cap; drop description default |
| Writes | Scope-first + no cast project_id | Latent IDOR before write tools |

## Open questions (resolved)

1. **P0-T1**: YES — MCPAuth runs in pipeline before `forward` to Anubis. DELETE/GET can halt 403; POST binds session.
2. Test DB user allows `CREATE EXTENSION pg_trgm` — confirmed in migrate.
3. Mutation tests use dual scopes `["project:read","project:write"]` — yes.

## Dead-ends (fill during work)

- (none)

## Spike result (P0-T1)

- Path chosen: **A**
- Notes: `ElxMcp.Auth.SessionBind` ETS; bind on POST with session header; verify DELETE/GET; unbind on successful DELETE ownership check. Unbound sessions allow lifecycle (window after initialize before next POST).

## Finding coverage checklist

- [x] Rate-limit ETS ownership
- [x] MCP session bind or Path C doc
- [x] Dual Scope + project:write + no cast project_id
- [x] Search ILIKE residual
- [x] Unbounded get_* preloads
- [x] comments/changelog get_*_id
- [x] Resources + tool asserts + 429

### [implementation] HANDOFF: ElxMCP P1 Residual
Status: 17/17 tasks done. Blockers: none.
Key decisions: Path A session bind; Application-owned ETS; Scope-first writes require project:write; search drops description by default; child_limit 50 on get_*.
