# wiki-rag-mcp

Automated RAG ingestion pipeline and MCP server for enterprise wikis powered by Qdrant and FastMCP via Docker Compose.

---

## Configuration

Settings are resolved first from Environment Variables, falling back to `config.json` when present on the host filesystem.

- **WIKI_TYPE**: Target wiki engine (`mediawiki` or `confluence`, default: `mediawiki`)
- **WIKI_URL**: Base URL of the wiki API (default: `https://en.wikipedia.org/w`)
- **AUTH_TOKEN**: Bearer token or API key if authentication is required (e.g., Confluence)
- **QDRANT_HOST**: Vector database hostname (default: `vector-db`)
- **QDRANT_PORT**: Vector database port (default: `6333`)
- **EMBED_MODEL_URL**: Base URL for generating vector embeddings (default: `http://host.docker.internal:1234/v1`)

---

## Ingestion Lifecycle & MCP Persistence

- **Fresh Snapshot Strategy:** On every execution, `src/ingest.py` automatically drops and recreates the `wiki` vector collection to clear out stale or deleted wiki pages.
- **Zero MCP Restart:** The MCP server queries Qdrant via stateless REST calls. When `ingest.py` recreates the collection, the MCP server immediately queries the new vector snapshot on its next tool call with zero downtime or server restarts.

---

## Option 1: Running on a Local Host Machine

Run the entire containerized stack on your local development machine using Docker Compose. All vector indexes persist to `./qdrant_data` on your host disk.

### 1. Launch the Stack
Spin up Qdrant and the MCP server in background mode:

```bash
docker compose up -d
```

### 2. Trigger Ingestion
Run the ingestor container on-demand on your local host whenever you need a sync:

```bash
docker compose run --rm ingestor
```

### 3. Connect Local LLM Client
Point host-level LLM clients (LM Studio, Claude Desktop, Cursor) to the MCP server endpoint running on your local host:

`http://localhost:8080/sse`

---

## Option 2: Running on a Cloud Host Machine

Deploy the container images to cloud container infrastructure (AWS, GCP, Azure, or a remote Linux host). Because the ingestor container runs to completion and exits cleanly, it can be scheduled on demand without running a 24/7 process.

### 1. Persistent Services (Vector DB & MCP Server)
Deploy `vector-db` and `mcp-server` as long-running, always-on container services on your cloud host / cluster:
- Expose port `8080` internally or behind an API gateway for client connections.
- Mount persistent cloud storage (e.g., AWS EBS, GCP Persistent Disk) to `/qdrant/storage`.

### 2. Scheduled Ingestor Execution
Invoke the `ingestor` container image on a scheduled cron trigger using cloud container orchestration:
- **AWS:** Trigger `ingestor` as an ECS / Fargate Task scheduled via Amazon EventBridge.
- **GCP:** Schedule `ingestor` as a Cloud Run Job managed by Cloud Scheduler.
- **Remote Cloud VM:** Schedule `docker run --rm ingestor` via standard host `crontab`.

---

## Testing Locally with LM Studio

LM Studio runs your chat model and embedding model locally while Docker Compose runs the MCP server and vector database.

### Step 1: Start the Docker Infrastructure
Launch Qdrant and the MCP server:

```bash
docker compose up -d
```

### Step 2: Set Up Models in LM Studio
1. Open LM Studio and download an embedding model (e.g., `text-embedding-all-minilm-l6-v2`) and a chat model (e.g., `Qwen2.5-7B-Instruct`).
2. Start the Local Server in LM Studio on port `1234`.
3. Verify that `http://localhost:1234/v1` is active.

### Step 3: Trigger Ingestion
Run the ingestor container to pull wiki pages, generate embeddings via LM Studio's embedding endpoint, and write them to Qdrant:

```bash
docker compose run --rm ingestor
```

### Step 4: Connect LM Studio to the MCP Server
1. Go to the Programmatic Access / MCP section in LM Studio.
2. Add a new SSE server entry:
   - **Server URL:** `http://localhost:8080/sse`
3. Connect to the server. You should see `search_wiki` listed under available tools.

### Step 5: Test the Pipeline
Open a new chat in LM Studio with your loaded chat model, ensure Tools/MCP function calling is enabled, and ask:

> "Search the wiki for authentication rules."

LM Studio will invoke `search_wiki`, retrieve relevant vector context from Qdrant, and output a grounded answer.