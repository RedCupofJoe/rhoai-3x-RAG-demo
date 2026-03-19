#!/usr/bin/env python3
"""
Chunk parsed markdown and upsert into Milvus vector DB.
Uses sentence-transformers for embeddings; creates collection if not exists.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from pymilvus import MilvusClient, DataType
from sentence_transformers import SentenceTransformer


def chunk_text(text: str, chunk_size: int = 512, overlap: int = 64) -> list[str]:
    """Simple sliding-window chunking by character count."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunk = text[start:end]
        if chunk.strip():
            chunks.append(chunk.strip())
        start = end - overlap
    return chunks


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", type=str, default="/workspace/input")
    parser.add_argument("--milvus-host", type=str, default="milvus.rag-demo.svc")
    parser.add_argument("--milvus-port", type=str, default="19530")
    parser.add_argument("--collection", type=str, default="rag_docs")
    parser.add_argument("--chunk-size", type=int, default=512)
    parser.add_argument("--chunk-overlap", type=int, default=64)
    parser.add_argument("--embedding-model", type=str, default="all-MiniLM-L6-v2")
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    md_files = list(input_dir.glob("**/*.md"))
    if not md_files:
        print("No markdown files in", input_dir)
        return 0

    model = SentenceTransformer(args.embedding_model)
    dim = model.get_sentence_embedding_dimension()
    uri = f"http://{args.milvus_host}:{args.milvus_port}"

    client = MilvusClient(uri=uri)
    schema = client.create_schema(
        auto_id=False,
        enable_dynamic_field=True,
    )
    schema.add_field(field_name="id", datatype=DataType.VARCHAR, max_length=64, is_primary=True)
    schema.add_field(field_name="text", datatype=DataType.VARCHAR, max_length=65535)
    schema.add_field(field_name="source", datatype=DataType.VARCHAR, max_length=512)
    schema.add_field(field_name="vector", datatype=DataType.FLOAT_VECTOR, dim=dim)
    if not client.has_collection(args.collection):
        client.create_collection(collection_name=args.collection, schema=schema)

    all_ids, all_texts, all_sources, all_vectors = [], [], [], []
    for md_path in md_files:
        text = md_path.read_text(encoding="utf-8")
        chunks = chunk_text(text, chunk_size=args.chunk_size, overlap=args.chunk_overlap)
        if not chunks:
            continue
        vecs = model.encode(chunks).tolist()
        for i, c in enumerate(chunks):
            uid = hashlib.sha256(f"{md_path.name}:{i}:{c[:64]}".encode()).hexdigest()[:64]
            all_ids.append(uid)
            all_texts.append(c[:65535])
            all_sources.append(str(md_path.name))
            all_vectors.append(vecs[i])

    if not all_ids:
        print("No chunks to insert")
        return 0

    data = [
        {"id": id_, "text": t, "source": s, "vector": v}
        for id_, t, s, v in zip(all_ids, all_texts, all_sources, all_vectors)
    ]
    client.insert(collection_name=args.collection, data=data)
    print(f"Inserted {len(data)} chunks into {args.collection}")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
