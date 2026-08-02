# ElxMCP

Servidor **MCP (Model Context Protocol)** em **Phoenix/Elixir** que expõe o **status de projetos** no estilo Jira (épicos, user stories, tickets, sprints, boards, etc.) para clientes de IA (Cursor, Claude Desktop, Grok, etc.).

Os dados ficam no **PostgreSQL** (host configurável via `.env`). Cada cliente autentica-se com uma **API Key** (`X-API-Key`) associada a **um projeto** e a um e-mail. O MCP é **somente leitura** no MVP.

## O que este projeto faz

- **Multi-tenant**: vários projetos no mesmo banco; isolamento por `project_id` da API Key
- **Modelo de trabalho**: Project → Epic → User Story → Ticket (+ sub-tasks)
- **Extras**: boards, sprints, components, comments, attachments, worklogs, changelogs
- **Keys estilo Jira**: `{PROJECT_KEY}-{N}` (ex.: `DEMO-1`)
- **MCP** (`anubis_mcp`): tools + resources em `/mcp` (Streamable HTTP)
- **Auth**: chave de 32 bytes (hex), hash SHA-256 no banco; geração via seeds ou mix task

Documentação de produto/técnico: [`spec/SPEC.md`](spec/SPEC.md).

## Requisitos

- Elixir ~> 1.17
- PostgreSQL acessível (ver `config/dev.exs` — hostname, user, database)
- Node (assets / Tailwind, se for usar a UI Phoenix)

## Setup

### Segredos locais (`.env`)

O arquivo **`.env`** (valores reais) não deve ir para o git. Use **`.env.example`** como template e, se quiser versionar o segredo de forma cifrada, **`.env.gpg`**.

```bash
# Cifrar .env → .env.gpg (AES-256 + S2K SHA-512)
mix elx_mcp.env.encrypt
mix elx_mcp.env.encrypt --force

# Decifrar .env.gpg → .env
mix elx_mcp.env.decrypt --force

# Sem prompt (CI / terminal sem TTY):
export ELX_MCP_GPG_PASSPHRASE='sua-passphrase-forte'
mix elx_mcp.env.encrypt --force
unset ELX_MCP_GPG_PASSPHRASE
```

A passphrase **não** passa por `/dev/tty` (evita `gpg: cannot open '/dev/tty'` em IDEs).
Use o prompt do Mix ou a variável `ELX_MCP_GPG_PASSPHRASE`.

```bash
# Dependências + DB + assets
mix setup

# Se o banco já existe e só falta migrar:
mix ecto.migrate

# Dados de demonstração (projeto DEMO + 1 API key impressa uma vez)
mix run priv/repo/seeds.exs

# Servidor
mix phx.server
# ou: iex -S mix phx.server
```

- App: [http://localhost:4000](http://localhost:4000)
- MCP: [http://localhost:4000/mcp](http://localhost:4000/mcp)

### Nova API key

```bash
mix elx_mcp.gen_api_key --project DEMO --email you@example.com --name "Cursor"
```

O plaintext da chave aparece **só uma vez** no terminal. Use no header:

```http
X-API-Key: <64 caracteres hex>
```

## Como testar

### 1. Testes automatizados

```bash
# Suite completa (compile + format + test via alias do projeto)
mix precommit

# Só os testes
mix test

# Arquivo específico
mix test test/elx_mcp/auth_test.exs
mix test test/elx_mcp/mcp/tools_test.exs
```

A suíte cobre contexts (tenancy, projects, auth, collaboration), plug `MCPAuth`, tools MCP e isolamento multi-tenant.

### 2. Smoke manual do MCP (com servidor no ar)

Com `mix phx.server` e uma API key (do seed ou do mix task):

**Sem chave → 401**

```bash
curl -s -X POST http://127.0.0.1:4000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": { "name": "cli", "version": "0.1.0" }
    }
  }'
# → {"error":"unauthorized"}
```

**Com chave → initialize (200)**

```bash
export API_KEY="<sua-chave-hex-64>"

curl -s -D - -X POST http://127.0.0.1:4000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "X-API-Key: $API_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-06-18",
      "capabilities": {},
      "clientInfo": { "name": "cli", "version": "0.1.0" }
    }
  }'
```

Guarde o header de resposta `mcp-session-id` e use-o nas próximas chamadas (`tools/list`, `tools/call`, etc.).

**Exemplo: listar tools**

```bash
# Após initialize + notifications/initialized (ver cliente MCP ou sessão curl)
curl -s -X POST http://127.0.0.1:4000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "X-API-Key: $API_KEY" \
  -H "mcp-session-id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

Tools úteis: `project_status`, `list_epics`, `list_user_stories`, `list_tickets`, `search_work_items`, `list_sprints`, `list_boards`, etc. (descrições bilíngues PT/EN).

### 3. Cadastrar o MCP no cliente e passar a API Key

O ElxMCP **não** usa transporte `stdio`. Ele é um servidor **HTTP Streamable** (protocolo MCP sobre HTTP). O cliente precisa:

1. Saber a **URL** do endpoint  
2. Enviar a **API Key** em **todo** request no header HTTP `X-API-Key`  
3. Manter o servidor Phoenix no ar (`mix phx.server`)

| Campo | Valor (dev local) |
|-------|-------------------|
| URL | `http://127.0.0.1:4000/mcp` (ou `http://localhost:4000/mcp`) |
| Header obrigatório | `X-API-Key` |
| Valor do header | a chave hex de 64 caracteres (do seed ou do `mix elx_mcp.gen_api_key`) |
| Nome no protocolo | **ElxMCP Project Status** (v0.2.0) |

> **Importante:** a autenticação é o header `X-API-Key`. Não use query string (`?api_key=`) nem body JSON para a chave. Sem o header (ou com chave inválida/revogada) a resposta é **HTTP 401**.

#### Obter a chave antes de cadastrar

```bash
# 1) Servidor + seed (imprime a key uma vez)
mix phx.server   # em outro terminal, se ainda não estiver rodando
mix run priv/repo/seeds.exs

# 2) Ou gerar outra key para o seu e-mail / cliente
mix elx_mcp.gen_api_key --project DEMO --email you@example.com --name "Cursor"
```

Copie a linha `key:` / `X-API-Key:` do output e guarde em local seguro (password manager). **Não commite** a chave no git.

#### Cursor

1. Abra **Cursor Settings → MCP** (ou edite o arquivo de config MCP do Cursor).  
2. Adicione um servidor HTTP / Streamable HTTP (não “command/stdio”).  
3. Preencha URL e headers, por exemplo em JSON de configuração:

```json
{
  "mcpServers": {
    "elx-mcp": {
      "url": "http://127.0.0.1:4000/mcp",
      "headers": {
        "X-API-Key": "COLE_AQUI_A_CHAVE_HEX_DE_64_CARACTERES"
      }
    }
  }
}
```

4. Salve, reinicie o MCP / o Cursor se necessário.  
5. Confirme que o servidor aparece como conectado e que as tools (`project_status`, `list_tickets`, …) listam.

Se a UI do Cursor pedir tipo de transporte, escolha **HTTP**, **Streamable HTTP** ou equivalente — **não** `stdio` / `npx` / comando shell, a menos que use um proxy.

#### Claude Desktop (e clientes com `claude_desktop_config.json`)

Muitos clientes ainda documentam só `stdio`. Para HTTP com headers, use a opção do seu cliente se existir (Streamable HTTP / remote MCP), ou um bridge. Quando o cliente suportar URL + headers:

```json
{
  "mcpServers": {
    "elx-mcp": {
      "url": "http://127.0.0.1:4000/mcp",
      "headers": {
        "X-API-Key": "COLE_AQUI_A_CHAVE_HEX_DE_64_CARACTERES"
      }
    }
  }
}
```

Arquivos comuns (dependem da versão do app):

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Outros: painel **Settings → Developer → MCP**

Reinicie o Claude Desktop após editar o JSON.

#### Outros clientes (Grok, VS Code MCP, etc.)

Regra geral:

| O que configurar | Valor |
|------------------|--------|
| Type / transport | HTTP Streamable (ou “remote MCP”) |
| Endpoint URL | `http://127.0.0.1:4000/mcp` |
| Custom headers | `X-API-Key` = `<sua-chave>` |

Exemplo conceitual (nomes de campos variam por app):

```yaml
# Pseudoconfig — adapte aos nomes do seu cliente
name: elx-mcp
transport: streamable_http   # ou http
url: http://127.0.0.1:4000/mcp
headers:
  X-API-Key: "COLE_AQUI_A_CHAVE_HEX_DE_64_CARACTERES"
```

#### Checklist se a conexão falhar

1. `mix phx.server` está rodando e [http://localhost:4000](http://localhost:4000) responde?  
2. A URL termina em **`/mcp`** (não só `/`)?  
3. O header se chama exatamente **`X-API-Key`** (case-insensitive no HTTP, mas o valor da chave deve ser o hex completo)?  
4. A chave tem **64** caracteres hex e não foi revogada?  
5. Teste com curl (secção 2): se o curl der 401, o problema é a key/servidor, não o cliente.  
6. Em produção/remoto: use HTTPS e coloque a origem do browser em `MCP_CORS_ORIGINS` se o cliente for web.

#### Uma key = um projeto

Cada API Key enxerga **apenas o projeto** ao qual foi ligada (`--project DEMO`). Para outro projeto, crie outra key:

```bash
mix elx_mcp.gen_api_key --project OUTRO --email you@example.com --name "Cursor Outro"
```

Cadastre no cliente um segundo servidor MCP (outro bloco `mcpServers`) com a URL igual e o `X-API-Key` da key desse projeto.

### 4. Dados de demo (após seeds)

Projeto **DEMO**, por exemplo:

- Épico `DEMO-1`
- Stories `DEMO-2`, `DEMO-3`
- Tickets `DEMO-4` … `DEMO-7`
- Board “Main Board”, Sprint 1

## Configuração do banco (`.env`)

O `config/runtime.exs` **carrega `.env` automaticamente** (sem sobrescrever variáveis já exportadas no shell).

### Variáveis separadas (recomendado)

```bash
# .env
DB_USER=your_db_user
DB_PASSWORD=your_db_password
DB_HOST=your_db_host
DB_PORT=5432
DB_NAME=elx_mcp_dev
DB_NAME_TEST=elx_mcp_test
DB_SSL=verify_none
POOL_SIZE=10
```

| Variável | Uso |
|----------|-----|
| `DB_USER` | usuário Postgres |
| `DB_PASSWORD` | senha |
| `DB_HOST` | servidor (ex.: `localhost`, hostname da sua rede) |
| `DB_PORT` | porta (padrão `5432`) |
| `DB_NAME` | database em dev |
| `DB_NAME_TEST` | database em test (padrão `elx_mcp_test`) |
| `DB_SSL` | `true` \| `false` \| `verify_none` |

### Ou uma URL única

```bash
DATABASE_URL=ecto://USER:PASSWORD@HOST:5432/elx_mcp_dev
DATABASE_URL_TEST=ecto://USER:PASSWORD@HOST:5432/elx_mcp_test
```

Se `DATABASE_URL` estiver definida, ela tem prioridade em dev/prod. Em test, usa-se `DATABASE_URL_TEST` se existir; senão, as vars `DB_*` + `DB_NAME_TEST`.

Template: [`.env.example`](.env.example). Valores locais: `.env` (não versionado).

## Configuração rápida

| Ambiente | DB | CORS MCP |
|----------|-----|----------|
| Dev | `.env` → `DB_*` ou `DATABASE_URL` | `*` (`allow_cors_star` em dev) |
| Test | `.env` → `DB_*` + `DB_NAME_TEST` | `*` em test |
| Prod | `DATABASE_URL` ou `DB_*` + `SECRET_KEY_BASE` | `MCP_CORS_ORIGINS` allowlist |

## Estrutura relevante

```text
lib/elx_mcp/
  tenancy/          # projects + issue keys
  projects/         # epics, stories, tickets, boards, sprints
  collaboration/    # comments, worklogs, changelogs, attachments
  auth/             # API keys, Scope, rate limit
  mcp/              # Anubis server, tools, resources
lib/elx_mcp_web/plugs/
  mcp_auth.ex       # X-API-Key
  cors.ex
spec/SPEC.md        # especificação do produto
```

## Produção

Guia genérico Phoenix: [Deployment](https://phoenixframework.org/docs/deployment).

Defina pelo menos: `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `MCP_CORS_ORIGINS` (origens explícitas).

## Learn more (Phoenix)

* [Phoenix Framework](https://www.phoenixframework.org/)
* [Guides](https://hexdocs.pm/phoenix/overview.html)
* [MCP / Anubis](https://hexdocs.pm/anubis_mcp)
