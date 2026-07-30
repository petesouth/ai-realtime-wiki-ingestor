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
    """Recreate the Qdrant vector collection on every ingestion run."""
    collections = [c.name for c in qdrant.get_collections().collections]
    
    # 1. Drop existing collection to clear old data
    if "wiki" in collections:
        qdrant.delete_collection("wiki")
        
    # 2. Create fresh collection schema
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
