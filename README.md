# wiki-rag-mcp

Automated RAG ingestion pipeline and MCP server for enterprise wikis powered by Qdrant and FastMCP via Docker Compose.

---

## Architecture Overview

- Vector DB: Qdrant container running on port 6333.
- Ingestor: Python container (`src/ingest.py`) that fetches wiki pages, generates vector embeddings, writes to Qdrant, and exits.
- MCP Server: FastMCP container exposing the `search_wiki` tool over SSE on port 8080.
- Inference Engine: Your local host's LLM manager (e.g., LM Studio) hosting chat and embedding models.

---

## Configuration

Settings are resolved first from Environment Variables, falling back to `config.json` when present on the host filesystem.

- WIKI_TYPE: Target wiki engine (default: `mediawiki`)
- WIKI_URL: Base URL of the wiki API (default: `https://en.wikipedia.org/w`)
- AUTH_TOKEN: Bearer token or API key if authentication is required
- QDRANT_HOST: Vector database hostname (default: `vector-db`)
- QDRANT_PORT: Vector database port (default: `6333`)
- EMBED_MODEL_URL: Base URL for generating vector embeddings (default: `http://host.docker.internal:1234/v1`)

---

## Ingestion Lifecycle & MCP Persistence

1. Fresh Snapshot Strategy: On every execution, `src/ingest.py` automatically drops and recreates the `wiki` vector collection to clear out stale or deleted wiki pages.
2. Zero MCP Restart: The MCP server queries Qdrant via stateless REST calls. When `ingest.py` recreates the collection, the MCP server immediately queries the new vector snapshot on its next tool call with zero downtime or server restarts.

---

## Testing locally with LM Studio

LM Studio runs your chat model and embedding model locally while Docker Compose runs the MCP server and vector database.

### Step 1: Start the Docker Infrastructure
Launch Qdrant and the MCP server in background mode:
docker compose up -d

### Step 2: Set Up Models in LM Studio
1. Open LM Studio and download an embedding model (e.g., `text-embedding-all-minilm-l6-v2`) and a chat model (e.g., `Qwen2.5-7B-Instruct`).
2. Start the Local Server in LM Studio on port `1234`.
3. Verify that `http://localhost:1234/v1` is active.

### Step 3: Trigger Ingestion
Run the ingestor container to pull wiki pages, generate embeddings via LM Studio's embedding endpoint, and write them to Qdrant:
docker compose run --rm ingestor

### Step 4: Connect LM Studio to the MCP Server
1. Go to the Programmatic Access / MCP section in LM Studio.
2. Add a new SSE server entry:
   - Server URL: `http://localhost:8080/sse`
3. Connect to the server. You should see `search_wiki` listed under available tools.

### Step 5: Test the Pipeline
Open a new chat in LM Studio with your loaded chat model, ensure Tools/MCP function calling is enabled, and ask:
> "Search the wiki for authentication rules."

LM Studio will invoke `search_wiki`, retrieve relevant vector context from Qdrant, and output a grounded answer.