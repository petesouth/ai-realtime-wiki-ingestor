#!/usr/bin/env bash
set -e

echo "Updating project files for wiki-rag-mcp..."

mkdir -p src

cat << 'EOF' > config.json
{
  "wiki_type": "mediawiki",
  "wiki_url": "https://en.wikipedia.org/w",
  "auth_token": "",
  "vector_db_host": "vector-db",
  "vector_db_port": 6333
}
EOF

cat << 'EOF' > requirements.txt
httpx>=0.27.0
qdrant-client>=1.9.0
fastmcp>=0.1.0
EOF

cat << 'EOF' > src/ingest.py
import os
import json
import httpx
from pathlib import Path
from qdrant_client import QdrantClient
from qdrant_client.models import VectorParams, Distance, PointStruct

def load_config() -> dict:
    config = {}
    config_file = Path("config.json")
    if config_file.exists():
        with open(config_file) as f:
            config = json.load(f)
            
    return {
        "wiki_type": os.getenv("WIKI_TYPE", config.get("wiki_type", "mediawiki")),
        "wiki_url": os.getenv("WIKI_URL", config.get("wiki_url", "https://en.wikipedia.org/w")),
        "auth_token": os.getenv("AUTH_TOKEN", config.get("auth_token", "")),
        "vector_db_host": os.getenv("QDRANT_HOST", config.get("vector_db_host", "vector-db")),
        "vector_db_port": int(os.getenv("QDRANT_PORT", config.get("vector_db_port", 6333)))
    }

config = load_config()

QDRANT_HOST = config["vector_db_host"]
QDRANT_PORT = config["vector_db_port"]
EMBED_URL = os.getenv("EMBED_MODEL_URL", "http://embed-model/v1") + "/embeddings"

qdrant = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)

def ensure_collection():
    collections = [c.name for c in qdrant.get_collections().collections]
    if "wiki" not in collections:
        qdrant.create_collection(
            collection_name="wiki",
            vectors_config=VectorParams(size=384, distance=Distance.COSINE)
        )

def get_embedding(text: str) -> list[float]:
    resp = httpx.post(EMBED_URL, json={"input": text}, timeout=30.0)
    resp.raise_for_status()
    return resp.json()["data"][0]["embedding"]

def fetch_and_ingest():
    ensure_collection()
    wiki_type = config.get("wiki_type")
    
    if wiki_type == "confluence":
        docs = fetch_confluence()
    elif wiki_type == "mediawiki":
        docs = fetch_mediawiki()
    else:
        print(f"Unsupported wiki_type: {wiki_type}")
        return

    points = []
    for idx, doc in enumerate(docs):
        if not doc["content"].strip():
            continue
        vector = get_embedding(doc["content"])
        points.append(
            PointStruct(
                id=idx,
                vector=vector,
                payload={"title": doc["title"], "text": doc["content"]}
            )
        )
    
    if points:
        qdrant.upsert(collection_name="wiki", points=points)
        print(f"Successfully ingested {len(points)} documents.")

def fetch_confluence():
    url = f"{config['wiki_url']}/api/v2/pages"
    headers = {"Authorization": f"Bearer {config.get('auth_token')}"}
    resp = httpx.get(url, headers=headers)
    pages = resp.json().get("results", [])
    
    docs = []
    for page in pages:
        body_resp = httpx.get(f"{url}/{page['id']}?body-format=storage", headers=headers)
        raw_html = body_resp.json().get("body", {}).get("storage", {}).get("value", "")
        clean_text = "".join([char for char in raw_html if char not in "<>"])
        docs.append({"title": page["title"], "content": clean_text})
    return docs

def fetch_mediawiki():
    url = f"{config['wiki_url']}/api.php?action=query&list=allpages&format=json"
    resp = httpx.get(url)
    pages = resp.json().get("query", {}).get("allpages", [])
    
    docs = []
    for page in pages:
        content_url = f"{config['wiki_url']}/api.php?action=query&titles={page['title']}&prop=revisions&rvprop=content&format=json"
        c_resp = httpx.get(content_url).json()
        pages_dict = c_resp.get("query", {}).get("pages", {})
        for _, pdata in pages_dict.items():
            content = pdata.get("revisions", [{}])[0].get("slots", {}).get("main", {}).get("content", "")
            docs.append({"title": page["title"], "content": content})
    return docs

if __name__ == "__main__":
    print("Executing run-to-completion wiki ingestion...")
    fetch_and_ingest()
    print("Ingestion run complete. Exiting.")
EOF

cat << 'EOF' > src/mcp_server.py
import os
import httpx
from fastmcp import FastMCP
from qdrant_client import QdrantClient

mcp = FastMCP("wiki-rag-mcp")

QDRANT_HOST = os.getenv("QDRANT_HOST", "vector-db")
QDRANT_PORT = int(os.getenv("QDRANT_PORT", 6333))
EMBED_URL = os.getenv("EMBED_MODEL_URL", "http://embed-model/v1") + "/embeddings"

qdrant = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)

@mcp.tool()
async def search_wiki(query: str, top_k: int = 3) -> str:
    """Search the internal ingested wiki database for relevant context."""
    async with httpx.AsyncClient() as client:
        resp = await client.post(EMBED_URL, json={"input": query}, timeout=30.0)
        vector = resp.json()["data"][0]["embedding"]

    results = qdrant.search(
        collection_name="wiki",
        query_vector=vector,
        limit=top_k
    )

    if not results:
        return "No relevant wiki articles found."

    formatted = []
    for res in results:
        title = res.payload.get("title", "Untitled")
        text = res.payload.get("text", "")
        formatted.append(f"[Source: {title}]\n{text}")

    return "\n\n---\n\n".join(formatted)

if __name__ == "__main__":
    mcp.run(transport="sse", port=8080)
EOF

cat << 'EOF' > Dockerfile.ingestor
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY config.json .
COPY src/ingest.py ./src/
CMD ["python", "-u", "src/ingest.py"]
EOF

cat << 'EOF' > Dockerfile.mcp
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/mcp_server.py ./src/
EXPOSE 8080
CMD ["python", "-u", "src/mcp_server.py"]
EOF

cat << 'EOF' > docker-compose.yaml
name: wiki-rag-mcp

services:
  vector-db:
    image: qdrant/qdrant:latest
    container_name: wiki_vector_db
    ports:
      - "6333:6333"
    volumes:
      - ./qdrant_data:/qdrant/storage
    restart: unless-stopped

  ingestor:
    build:
      context: .
      dockerfile: Dockerfile.ingestor
    container_name: wiki_ingestor
    models:
      - embed-model
    environment:
      - WIKI_TYPE=mediawiki
      - WIKI_URL=https://en.wikipedia.org/w
      - QDRANT_HOST=vector-db
      - QDRANT_PORT=6333
    depends_on:
      - vector-db

  mcp-server:
    build:
      context: .
      dockerfile: Dockerfile.mcp
    container_name: wiki_mcp_server
    ports:
      - "8080:8080"
    models:
      - embed-model
    environment:
      - QDRANT_HOST=vector-db
      - QDRANT_PORT=6333
    depends_on:
      - vector-db
    restart: unless-stopped

models:
  embed-model:
    model: ai/all-minilm
    context_size: 2048
EOF

cat << 'EOF' > README.md
# wiki-rag-mcp

Automated RAG ingestion pipeline and MCP server for enterprise wikis powered by Qdrant and local embeddings via Docker Compose.

## Architecture

- Vector DB: Qdrant container on port 6333.
- Docker Model Runner: Top-level model runner (ai/all-minilm).
- Ingestor: Python script (src/ingest.py) fetching wiki pages and generating vectors.
- MCP Server: FastMCP exposing search_wiki over SSE on port 8080.

## Usage

Start services:
docker compose up --build

Trigger ingestion:
docker compose run --rm ingestor

## Cloud Scheduling

The ingestor runs once and exits cleanly, making it suitable for scheduled cloud jobs:
- AWS ECS/Fargate Task triggered by EventBridge
- GCP Cloud Run Job scheduled via Cloud Scheduler
- Kubernetes CronJob targeting a Qdrant cluster endpoint
EOF

echo "Project updated cleanly."