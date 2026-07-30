# wiki-rag-mcp

Automated RAG ingestion pipeline and MCP server for enterprise wikis powered by Qdrant and FastMCP via Docker Compose.

---

## Architecture Overview

- Vector DB: Qdrant container running on port 6333.
- Ingestor: Python container (`src/ingest.py`) that fetches wiki pages, generates vector embeddings, writes to Qdrant, and exits.
- MCP Server: FastMCP container exposing the `search_wiki` tool over SSE on port 8080.
- Inference Engine: Your local host's LLM manager (e.g., LM Studio) hosting chat and embedding models.

---

## Supported Wiki Platforms

The ingestor includes built-in API parsers for two major wiki platforms out of the box:

- **MediaWiki:** Public or self-hosted MediaWiki instances (e.g., Wikipedia, internal company wikis). Queries the standard `api.php` endpoints to fetch page lists and revision content.
- **Atlassian Confluence:** Enterprise Confluence Cloud or Data Center spaces. Connects via `/api/v2/pages` using a Bearer token (`AUTH_TOKEN`) to extract page storage format and sanitize HTML down to clean plain text.

### Extending to Other Platforms
Because `src/ingest.py` uses a clean modular structure, adding support for other documentation engines (such as Notion, GitHub Wikis, Docusaurus, or GitBook) only requires adding a new `fetch_` function that returns a list of title and content dictionaries:

```python
def fetch_custom_wiki() -> list[dict]:
    # Fetch raw pages from target API
    return [{"title": "Page Title", "content": "Clean plain text content..."}]