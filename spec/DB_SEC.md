# DB_SEC — Segurança de acesso ao PostgreSQL (ElxMCP)

> **Status:** v1.0 — auditoria e plano de remediação (dev + hardening)  
> **App:** `elx_mcp` (Phoenix 1.8 + Ecto + PostgreSQL)  
> **Host de referência (auditoria):** `hermes` (dev; IP público observado na auditoria)  
> **Data da auditoria de base:** 2026-08-02  
> **Escopo:** credenciais, rede, privilégios de role, TLS, multi-DB, config Ecto/runtime, secrets no git  
> **Fora de escopo:** XSS/CSRF na UI, hardening completo do SO, RDS-IAM como controle primário

Documento irmão de `spec/SPEC.md`. Complementa a especificação de produto com **controles de segurança do banco**.

---

## 1. Veredito

O acesso ao PostgreSQL **pode ser comprometido** no estado auditado se o servidor estiver exposto na internet com senha fraca e role com privilégios excessivos (multi-database + `CREATEROLE`/`CREATEDB`).

A camada de aplicação (API keys SHA-256, escopo por `project_id`, rate limit MCP) **não** substitui least privilege e isolamento de rede no Postgres: a app conecta com um role que enxerga o schema inteiro.

| Área | Avaliação |
| ---- | --------- |
| Exposição de rede (`5432` em host público) | Crítico |
| Qualidade da senha (padrão usuário == senha) | Crítico |
| Escopo de privilégios (multi-DB + CREATEROLE) | Alto |
| TLS sem verificação de certificado na app (`verify_none`) | Alto |
| Isolamento multi-tenant no PG (sem RLS) | Médio (defesa em profundidade) |
| Segredos cifrados versionados (`.env.gpg`) | **Mitigado (v1.8):** removido do tracking; ainda pode existir no histórico git |
| Auth MCP / API keys / queries Ecto | Razoável — manter |

**Score orientativo de risco de acesso ao DB (auditoria):** ~18/100 (quanto menor, pior o risco residual de exposição).

---

## 2. Achados (resumo)

### 2.1 Críticos

| ID | Achado | Impacto |
| -- | ------ | ------- |
| C1 | Postgres com `listen_addresses = *` e porta **5432** alcançável em IP público | Brute-force / scan na internet |
| C2 | Credencial de app fraca (padrão `user == password` em dev) | Login autenticado trivial se a senha vazar ou for adivinhada |
| C3 | Role de app com `CONNECT` em **vários** databases do cluster (ex.: outros projetos no mesmo host) | Um vazamento = blast radius multi-produto |

### 2.2 Altos

| ID | Achado | Impacto |
| -- | ------ | ------- |
| A1 | Role com `CREATEROLE` e `CREATEDB` | Backdoor de roles; novos DBs; persistência pós-rotação |
| A2 | App com `DB_SSL=verify_none` contra host remoto | MITM na rota até o servidor |
| A3 | Role owner com DML+DDL+TRUNCATE em todas as tabelas; **RLS desligado** | Sem least privilege no PG; isolamento só na app |

### 2.3 Médios

| ID | Achado | Impacto |
| -- | ------ | ------- |
| M1 | `.env.gpg` versionado no git (AES-256 GPG simétrico) | Offline attack se passphrase fraca; histórico permanente |
| M2 | Fallbacks `postgres`/`postgres` em non-prod no `runtime.exs` | Conexão acidental com defaults clássicos |
| M3 | Pouca observabilidade de auth (`log_connections` / falhas) | Brute-force sem trilha |

### 2.4 Controles que estão bem (não regredir)

- `password_encryption = scram-sha-256`; SSL no servidor (TLS 1.3 observado).
- Role de app **não** é superuser; sem leitura de `pg_authid`.
- `.env` no `.gitignore`; prod exige credenciais e `SECRET_KEY_BASE`.
- Em prod, default de SSL verificado (`DB_SSL` default `true`) e warning se `verify_none`.
- API keys hasheadas (SHA-256); queries com bind (`^`); escape em `ILIKE`; MCP auth + rate limit + session bind.

---

## 3. Cadeia de comprometimento (cenário mais provável)

```
1. Scanner/Internet encontra host:5432 (se público)
2. Credencial fraca ou vazada (arquivo, git cifrado, reuso)
3. Login SSL (SCRAM) bem-sucedido
4. SELECT/DML em elx_mcp_* e, se multi-DB, outros databases
5. CREATE ROLE backdoor / dump / wipe (se CREATEROLE ou owner)
6. Camada MCP irrelevante para quem já tem a senha do DB
```

---

## 4. Desenvolvimento vs. least privilege

### 4.1 O que o dev do ElxMCP **precisa**

| Fluxo Mix | Privilégio Postgres necessário |
| --------- | ------------------------------ |
| `mix ecto.create` / `ecto.drop` / `ecto.reset` | `CREATEDB` **ou** DBs pré-criados por admin |
| `mix ecto.migrate` | DDL no schema (ideal: **owner** das tabelas) |
| `mix test` (alias cria/migra test) | Idem em `elx_mcp_test` |
| seeds / runtime | SELECT, INSERT, UPDATE, DELETE |
| migration `pg_trgm` | `CREATE EXTENSION` (muitas vezes **admin uma vez**) |

Aliases relevantes (`mix.exs`): `ecto.setup`, `ecto.reset`, `test` → `ecto.create` + `ecto.migrate`.

### 4.2 O que **não** é requisito de desenvolvimento

| Privilégio / acesso | Necessário para Mix/Ecto? |
| ------------------- | ------------------------- |
| `CREATEROLE` | **Não** |
| Superuser | **Não** (exceto bootstrap de extension) |
| `CONNECT` em databases de outros produtos | **Não** |
| `TRUNCATE` explícito além de ownership | Não como grant separado em dev solo |

### 4.3 O que cortar demais **quebra** o dev

| Mudança agressiva | Efeito |
| ----------------- | ------ |
| Remover `CREATEDB` sem pré-criar DBs | Falha `ecto.create` / `ecto.reset` / `mix test` |
| Só DML (sem ownership/DDL) | Falha `ecto.migrate` |
| Sem permissão de extension e sem admin prévio | Migration `pg_trgm` pode falhar; `ILIKE` ainda funciona |

### 4.4 Níveis de endurecimento em dev

**Nível A — impacto ~zero no ElxMCP (recomendado já):**

1. `NOCREATEROLE` no role de app/dev.
2. Revogar `CONNECT` em databases que não sejam `elx_mcp_*`.
3. Senha forte + rede restrita (VPN / allowlist / private).
4. Manter: `LOGIN`, `CREATEDB` (ou DBs pré-criados), owner de `elx_mcp_dev` / `elx_mcp_test`.

**Nível B — least privilege ainda compatível com dev:**

| Role | Uso | Privs |
| ---- | --- | ----- |
| Role de app/dev **`elx_mcp_dev`** | Mix + app no dia a dia | Owner **somente** de `elx_mcp_dev` / `elx_mcp_test`; `NOCREATEROLE`; `CREATEDB` (ecto.reset) |
| Superuser / admin do host | Bootstrap | `CREATE EXTENSION`, `pg_hba`, criar DBs se necessário |

Regra de ouro:

> **Reduza blast radius (outros DBs, CREATEROLE, rede, senha).**  
> **Mantenha o ciclo de vida do schema do ElxMCP (create / migrate / seed / test).**

---

## 5. Plano de remediação

### 5.1 Imediato (hoje / antes de qualquer exposição)

| # | Ação | Notas |
| - | ---- | ----- |
| 1 | **Rotacionar senha** do role usado pela app | Longa, aleatória; atualizar `.env` / secret store |
| 2 | **Restringir rede:** fechar `5432` na internet | VPN, Tailscale, WireGuard, VPC privada ou allowlist de IPs |
| 3 | Revisar **`pg_hba.conf`**: só SSL, só redes confiáveis, sem `trust` remoto | Admin no host |
| 4 | **Revogar `CONNECT`** em databases alheios ao ElxMCP | Ver §6.2 |
| 5 | **`NOCREATEROLE`** (e preferir `NOCREATEDB` se DBs já existem) | Ver §6.1 |

### 5.2 Curto prazo (esta semana)

| # | Ação | Notas |
| - | ---- | ----- |
| 6 | Role dedicado por app (`elx_mcp_app`) + grants mínimos | Opcional migrator separado em CI/prod |
| 7 | App com `DB_SSL=true` + CA confiável; eliminar `verify_none` fora de lab local | **Feito (v1.4):** peer verify + `DB_SSL_CA` hermes |
| 8 | Política de `.env.gpg`: não versionar se remoto amplo; ou GPG assimétrico; **rotacionar** se já commitado | **Feito (v1.8):** `.gitignore` + `git rm --cached`; histórico antigo ainda tem o blob |
| 9 | Logs de autenticação + monitoramento de falhas | **Feito (v1.4):** `log_connections` / collector no hermes |
| 10 | Remover defaults `postgres`/`postgres` no `runtime.exs` | **Feito (v1.2):** falha se faltar `DB_USER`/`DB_PASSWORD`/`DB_HOST` |

### 5.3 Médio prazo

| # | Ação |
| - | ---- |
| 11 | Segredos só em secret manager / CI secrets | **Parcial (v1.7):** CI via GitHub Actions Secrets (`.github/workflows/ci.yml`) |
| 12 | Avaliar RLS se multi-tenant forte no mesmo role/DB for requisito de compliance | **Feito (v1.6):** FORCE RLS + GUC `app.project_id` / `app.bypass_rls` |
| 13 | Backup cifrado + restore testado; inventário de roles (`\du`) no checklist de deploy | **Feito (v1.5):** `mix db.backup` + `mix db.backup.verify` |
| 14 | Hardening CIS PostgreSQL (extensões, limites, auditoria) | **Feito (v1.6):** limits, logging, `mix db.cis_check` |

---

## 6. Scripts e exemplos de correção

> Executar como **superuser** ou role admin no host, em sessão administrativa segura.  
> Ajustar nomes de role/database conforme o ambiente.  
> **Não** colar senhas reais neste repositório.

### 6.1 Endurecimento do role atual (Nível A — dev-safe)

```sql
-- Remover capacidade de criar roles (não usada pelo Ecto)
ALTER ROLE aquental NOSUPERUSER NOCREATEROLE;

-- Opcional: se elx_mcp_dev e elx_mcp_test já existem e você não precisa de ecto.create:
-- ALTER ROLE aquental NOCREATEDB;
```

### 6.2 Isolar databases (revogar multi-DB)

```sql
-- Exemplos do cluster auditado — adaptar à lista real:
REVOKE ALL ON DATABASE loja_dev FROM aquental;
REVOKE ALL ON DATABASE ceci_kinde_dev FROM aquental;
REVOKE ALL ON DATABASE hello_dev FROM aquental;

-- Preferência: CONNECT apenas onde necessário
GRANT CONNECT ON DATABASE elx_mcp_dev TO aquental;
GRANT CONNECT ON DATABASE elx_mcp_test TO aquental;

-- Endurecimento geral (como admin, com cuidado em clusters compartilhados):
-- REVOKE CONNECT ON DATABASE <nome> FROM PUBLIC;
```

### 6.3 Role dedicado (recomendado para prod e bom em dev)

```sql
-- 1) Role de aplicação (sem CREATEROLE; CREATEDB opcional em dev)
CREATE ROLE elx_mcp_app LOGIN PASSWORD '<senha-longa-aleatória>'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

-- 2) Databases (se ainda não existirem — como superuser)
CREATE DATABASE elx_mcp_dev OWNER elx_mcp_app;
CREATE DATABASE elx_mcp_test OWNER elx_mcp_app;

-- 3) Se os DBs já existem e as tabelas são de outro owner:
GRANT CONNECT ON DATABASE elx_mcp_dev TO elx_mcp_app;
GRANT CONNECT ON DATABASE elx_mcp_test TO elx_mcp_app;

-- Dentro de cada database elx_mcp_*:
GRANT USAGE ON SCHEMA public TO elx_mcp_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO elx_mcp_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO elx_mcp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO elx_mcp_app;

-- Dev com migrations: preferir OWNER das tabelas/DB em vez de só DML.
-- Ex.: reassign se migrar de aquental → elx_mcp_app:
-- REASSIGN OWNED BY aquental TO elx_mcp_app;  -- só dentro do DB alvo, com cuidado
```

### 6.4 Extension `pg_trgm` (uma vez, como admin)

A migration `priv/repo/migrations/20260802120000_enable_pg_trgm_search.exs` executa `CREATE EXTENSION IF NOT EXISTS pg_trgm`. Se o role de app não puder criar extensions:

```sql
-- Como superuser, no database elx_mcp_dev (e test se necessário):
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

Sem a extension, busca por `ILIKE` no título **continua**; índices GIN de similaridade podem não ser criados.

### 6.5 Rede e `listen_addresses` (admin do host)

Objetivos:

1. Postgres **não** escutar na internet aberta (`0.0.0.0` / `* ` sem firewall).
2. Preferir rede privada, bastion ou tunnel.
3. Firewall: allowlist só de IPs da app / VPN.

Exemplos de direção (não aplicar cegamente):

```text
# postgresql.conf (preferência)
listen_addresses = 'localhost'   # ou IP privado da VPC
# + reverse tunnel / VPN para dev remoto
```

`pg_hba.conf` (direção):

```text
# Apenas SSL + redes conhecidas (exemplos)
# hostssl  elx_mcp_dev  elx_mcp_app  10.0.0.0/8   scram-sha-256
# hostssl  elx_mcp_test elx_mcp_app  10.0.0.0/8   scram-sha-256
# Nunca: trust para redes remotas
# Evitar: host all all 0.0.0.0/0 md5  (aberto)
```

### 6.6 TLS na aplicação

| Ambiente | `DB_SSL` recomendado |
| -------- | -------------------- |
| Lab local (Postgres no mesmo host, cert self-signed sem CA) | `verify_none` **só** se rede for loopback/confiável |
| Dev remoto (`hermes` / qualquer host não-local) | `true` + CA confiável |
| Produção | `true` (default do `runtime.exs` em prod) |

Configurar CA do cliente (`sslrootcert=system` ou arquivo CA do servidor). Validar com `sslmode=verify-full` no `psql` antes de assumir MITM-proof.

### 6.7 Observabilidade no Postgres

```sql
-- Via postgresql.conf / ALTER SYSTEM (admin):
-- log_connections = on
-- log_disconnections = on
-- log_min_error_statement = error
-- (avaliar log de falhas de autenticação no log do servidor)
```

Complementar com firewall rate-limit / fail2ban no host, se exposto a qualquer rede semi-pública.

---

## 7. Segredos e repositório

| Artefato | Política |
| -------- | -------- |
| `.env` | **Nunca** commitar (já no `.gitignore`) |
| `.env.example` | Só placeholders; sem senhas reais |
| `.env.gpg` | **Nunca** versionar (`.gitignore`). Cópia local opcional via `mix elx_mcp.env.encrypt`. Histórico git antigo pode ainda conter blobs — rotacionar credenciais se o repo for/foi público |
| `ELX_MCP_GPG_PASSPHRASE` | Nunca no git; não logar |
| `SECRET_KEY_BASE` | Dev pode ser local; **nunca** reutilizar valor de `dev.exs` em prod |
| `DATABASE_URL` / `DB_PASSWORD` | Secret manager em CI/prod |

Se `.env.gpg` **já** estiver no histórico com senhas reais: assumir comprometimento futuro da passphrase e **rotacionar** todas as credenciais contidas.

Mix tasks existentes: `mix elx_mcp.env.encrypt` / `mix elx_mcp.env.decrypt` (AES-256 + S2K SHA-512).

---

## 8. Configuração da aplicação (referência)

| Item | Onde | Direção de segurança |
| ---- | ---- | -------------------- |
| Carregar `.env` | `config/runtime.exs` | Não sobrescrever env já setada (ok) |
| `DB_SSL` | `runtime.exs` + `.env` | **`true` + peer verify** (`DB_SSL_CA` / system CAs; `DB_SSL_HOSTNAME` se alias) |
| Fallbacks `postgres`/`postgres` | `runtime.exs` `repo_from_parts` | **Removidos** — raise se faltar `DB_USER`/`DB_PASSWORD`/`DB_HOST` |
| Credenciais prod | `runtime.exs` | Já exige `DATABASE_URL` ou `DB_*` (manter) |
| `show_sensitive_data_on_connection_error` | `config/dev.exs` | Manter **só** em dev |
| LiveDashboard `/dev` | `router.ex` + `dev_routes` | Nunca habilitar em prod sem auth forte |
| MCP CORS `*` | dev only | Prod: allowlist em `MCP_CORS_ORIGINS` |

Variáveis documentadas em `.env.example`: `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_NAME_TEST`, `DB_SSL`, `POOL_SIZE`, `DATABASE_URL`, `DATABASE_URL_TEST`.

---

## 9. Checklist de verificação pós-fix

```bash
# 1) De IP/rede NÃO autorizada: deve FALHAR
psql "host=<host-publico> port=5432 user=elx_mcp_app dbname=elx_mcp_dev sslmode=require"

# 2) De rede autorizada com CA: deve PASSAR
psql "host=<host-privado> port=5432 user=elx_mcp_app dbname=elx_mcp_dev sslmode=verify-full sslrootcert=system"

# 3) No servidor (admin)
# \du                          → role de app SEM CREATEROLE (e preferir SEM CREATEDB se DBs fixos)
# \l                           → CONNECT só em elx_mcp_*
# show listen_addresses;       → não público sem firewall
# SELECT rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname = 'elx_mcp_app';
```

Fluxo app (dev) deve continuar:

```bash
mix ecto.create   # ou DBs já existentes
mix ecto.migrate
mix test
mix phx.server
```

---

## 10. Matriz de decisão rápida

| Ação | Dev ElxMCP | Segurança | Prioridade |
| ---- | ---------- | --------- | ---------- |
| Rotacionar senha fraca | Não quebra (atualiza `.env`) | Crítica | P0 |
| Fechar `5432` público / VPN | Pode exigir tunnel | Crítica | P0 |
| `NOCREATEROLE` | Não quebra | Alta | P0 |
| REVOKE multi-DB | Não quebra ElxMCP | Alta | P0 |
| Role dedicado owner de `elx_mcp_*` | OK se owner/DDL | Alta | P1 |
| `DB_SSL=true` + CA | **Feito** (CA pin + hostname) | Alta | P1 ✅ |
| Remover defaults `postgres`/`postgres` | **Feito** — exige `.env` / env completo | Média | P1 ✅ |
| Remover `.env.gpg` do git / rotacionar | **Removido do tree (v1.8)**; rotação de passphrase/histórico opcional | Média | P1 ✅ |
| `NOCREATEDB` + DBs pré-criados | OK se bootstrap feito | Média | P2 |
| RLS por `project_id` | Não obrigatório MVP | Defesa em profundidade | P2 |
| Logs de conexão/auth | **Feito** no hermes | Média | P2 ✅ |

---

## 11. Limitações da auditoria de origem

- Leitura de `pg_hba.conf` / `data_directory` negada ao role de app (esperado).
- Sem dump de dados de outros produtos; apenas prova de `CONNECT` e contagens.
- Sem hardening completo do SO do host `hermes`.
- Estado do ambiente **muda** após remediação — revalidar com o checklist do §9.

---

## 12. Referências internas

| Recurso | Caminho |
| ------- | ------- |
| Spec de produto | `spec/SPEC.md` |
| Runtime / DB SSL | `config/runtime.exs` |
| Dev (sensitive connection errors) | `config/dev.exs` |
| Template de env | `.env.example` |
| Migration pg_trgm | `priv/repo/migrations/20260802120000_enable_pg_trgm_search.exs` |
| Auth API keys | `lib/elx_mcp/auth.ex` |
| Plug MCP | `lib/elx_mcp_web/plugs/mcp_auth.ex` |
| Encrypt/decrypt env | `mix elx_mcp.env.encrypt` / `mix elx_mcp.env.decrypt` |

---

## 13. Estado aplicado (hermes)

| Item | Estado |
| ---- | ------ |
| Role | `elx_mcp_dev` — `LOGIN`, `CREATEDB`, **`NOCREATEROLE`**, não superuser |
| Owner de | `elx_mcp_dev`, `elx_mcp_test` (databases + objetos `public`) |
| Sem `CONNECT` em | `loja_*`, `ceci_kinde_*`, `hello_dev` (dados de outros produtos) |
| `CONNECT` em `postgres` | **Sim**, só catálogo de manutenção (`mix ecto.create` / `ecto.drop`) — sem tabelas de app |
| `pg_hba` | `hostssl`/`host` para `elx_mcp_*` + `postgres` (manutenção) + IP de dev allowlist + localhost |
| App local | `.env` → `DB_USER=elx_mcp_dev` (senha **não** versionada) |
| Porta do cluster | **`5481`** (não 5432) — `DB_PORT=5481` no `.env` |
| TLS app | `DB_SSL=true` + `DB_SSL_CA=priv/certs/hermes-pg-ca.pem` + `DB_SSL_HOSTNAME=vps8383.panel.icontainer.net` |
| Auth logs (PG) | `log_connections=on`, `log_disconnections=on`, `logging_collector=on` → `.../main/log/postgresql-YYYY-MM-DD.log` |
| Role `aquental` | **`NOCREATEROLE`**, senha rotacionada (forte); `CREATEDB` mantido para outros apps; sem CONNECT em `elx_mcp_*` |
| Backup cifrado | `scripts/db_backup.sh` / `mix db.backup` → `priv/backups/*.dump.gpg`; verify: `mix db.backup.verify` |
| CIS (v1.6) | `log_lock_waits`, `log_temp_files=10MB`, `log_min_duration_statement=1s`; `CONNECTION LIMIT` roles; extensions `plpgsql`+`pg_trgm` |
| RLS (v1.6) | FORCE RLS em tabelas tenant; policies `app.project_id` **ou** `app.bypass_rls=on`; `Repo.with_tenant/2`, `Repo.with_bypass/1` |

### 13.1 Backup e restore (operacional)

```bash
# Requer ELX_MCP_BACKUP_PASSPHRASE no .env
mix db.backup                 # dump + GPG AES-256 de elx_mcp_dev
./scripts/db_backup.sh --db both
mix db.backup.verify          # decrypt → DB temp → contagem de tabelas → DROP
```

Artefatos em `priv/backups/` (**gitignored**). Credenciais do role `aquental` (outros projetos): arquivo local `.aquental_db_credentials` (gitignored).

### 13.2 CIS check (read-only)

```bash
mix db.cis_check
# ou: ./scripts/db_cis_check.sh
```

### 13.3 RLS operacional

| GUC | Quem seta | Efeito |
| --- | --------- | ------ |
| `app.project_id` | `Repo.with_tenant/2` (contexts + MCP `with_scope`) | Isola linhas do projeto |
| `app.bypass_rls=on` | `Repo.with_bypass/1` (auth lookup, list projects) | Bypass **somente** via código confiado |

`schema_migrations` **sem** RLS. Owner com FORCE RLS; não-superuser **não** pode `SET row_security=off` — por isso o GUC de bypass.

Revalidar com o checklist do §9 após qualquer mudança de rede/IP.

---

## 14. Histórico

| Versão | Data | Notas |
| ------ | ---- | ----- |
| v1.0 | 2026-08-02 | Achados da auditoria + plano de remediação + orientação dev-safe de privilégios |
| v1.1 | 2026-08-02 | Role `elx_mcp_dev` criado no `hermes`; ownership e `pg_hba` isolados; `.env` / `.env.example` atualizados |
| v1.2 | 2026-08-02 | `runtime.exs`: removidos defaults `postgres`/`postgres`/`localhost`; exige `DB_USER`/`DB_PASSWORD`/`DB_HOST` |
| v1.3 | 2026-08-02 | Postgres no `hermes` na porta **5481**; `.env` / docs com `DB_PORT=5481` |
| v1.4 | 2026-08-02 | `DB_SSL=true` + peer verify (`priv/certs/hermes-pg-ca.pem`); logs de auth no hermes |
| v1.5 | 2026-08-02 | Role `aquental` endurecido; backup cifrado + restore verificado (`mix db.backup*`) |
| v1.6 | 2026-08-02 | CIS (limits/logging/check); FORCE RLS + tenant GUC + bypass GUC |
| v1.7 | 2026-08-02 | CI Option C: GitHub Actions Secrets + Postgres service (`ci.yml`) |
| v1.8 | 2026-08-02 | `.env.gpg` removido do tracking git (permanece só local + `.gitignore`) |
