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
