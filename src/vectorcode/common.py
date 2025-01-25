import asyncio
import hashlib
import os
import socket
import subprocess
import sys
from typing import Any, Coroutine, Optional

import aiohttp
import chromadb
import httpx
from chromadb.api import AsyncClientAPI
from chromadb.config import Settings
from chromadb.utils import embedding_functions

from vectorcode.cli_utils import Config, expand_path


def try_server(host: str, port: int):
    url = f"http://{host}:{port}/api/v1/heartbeat"
    try:
        with httpx.Client() as client:
            return client.get(url=url).status_code == 200
    except (httpx.ConnectError, httpx.ConnectTimeout):
        return False


async def wait_for_server(host, port, timeout=10):
    # Poll the server until it's ready or timeout is reached
    url = f"http://{host}:{port}/api/v1/heartbeat"
    start_time = asyncio.get_event_loop().time()
    async with aiohttp.ClientSession() as session:
        while True:
            try:
                async with session.get(url) as response:
                    if response.status == 200:
                        return
            except aiohttp.ClientConnectionError:
                pass  # Server is not yet ready

            if asyncio.get_event_loop().time() - start_time > timeout:
                raise TimeoutError(f"Server did not start within {timeout} seconds.")

            await asyncio.sleep(0.1)  # Wait before retrying


def start_server(configs: Config):
    assert configs.host is not None
    assert configs.port is not None
    assert configs.db_path is not None
    if not os.path.isdir(configs.db_path):
        print(
            f"Creating database at {os.path.expanduser('~/.local/share/vectorcode/chromadb/')}.",
            file=sys.stderr,
        )
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "chromadb.cli.cli",
            "run",
            "--host",
            configs.host,
            "--port",
            str(configs.port),
            "--path",
            str(configs.db_path),
            "--log-path",
            os.path.join(str(configs.project_root), "chroma.log"),
        ],
        stdout=subprocess.DEVNULL,
        stderr=sys.stderr,
        preexec_fn=os.setsid,
    )
    asyncio.run(wait_for_server(configs.host, configs.port))
    return process


def get_client(configs: Config) -> Coroutine[Any, Any, AsyncClientAPI]:
    assert configs.host is not None
    assert configs.port is not None
    assert configs.db_path is not None
    try:
        if configs.db_settings is not None:
            setting = Settings(**configs.db_settings)
        else:
            setting = None
        return chromadb.AsyncHttpClient(
            host=configs.host or "localhost",
            port=configs.port or 8000,
            settings=setting,
        )
    except ValueError:
        print(
            f"Failed to access the chromadb server at {configs.host}:{configs.port}. Please verify your setup and configurations."
        )
        sys.exit(1)


def get_collection_name(full_path: str) -> str:
    full_path = str(expand_path(full_path, absolute=True))
    hasher = hashlib.sha256()
    hasher.update(f"{os.environ['USER']}@{socket.gethostname()}:{full_path}".encode())
    collection_id = hasher.hexdigest()[:63]
    return collection_id


def get_embedding_function(configs: Config) -> Optional[chromadb.EmbeddingFunction]:
    try:
        return getattr(embedding_functions, configs.embedding_function)(
            **configs.embedding_params
        )
    except AttributeError:
        print(
            f"Failed to use {configs.embedding_function}. Falling back to Sentence Transformer.",
            file=sys.stderr,
        )
        return embedding_functions.SentenceTransformerEmbeddingFunction()


async def make_or_get_collection(client: AsyncClientAPI, configs: Config):
    full_path = str(expand_path(str(configs.project_root), absolute=True))
    collection = await client.get_or_create_collection(
        get_collection_name(full_path),
        metadata={
            "path": full_path,
            "hostname": socket.gethostname(),
            "created-by": "VectorCode",
            "username": os.environ["USER"],
            "embedding_function": configs.embedding_function,
        },
        embedding_function=get_embedding_function(configs),
    )
    if (
        not collection.metadata.get("hostname") == socket.gethostname()
        or not collection.metadata.get("username") == os.environ["USER"]
        or not collection.metadata.get("created-by") == "VectorCode"
    ):
        raise IndexError(
            "Failed to create the collection due to hash collision. Please file a bug report."
        )
    return collection


def verify_ef(collection, configs: Config):
    collection_ef = collection.metadata.get("embedding_function")
    collection_ep = collection.metadata.get("embedding_params")
    if collection_ef and collection_ef != configs.embedding_function:
        print(f"The collection was embedded using {collection_ef}.")
        print(
            "Embeddings and query must use the same embedding function and parameters. Please double-check your config."
        )
        return False
    elif collection_ep and collection_ep != configs.embedding_params:
        print(
            f"The collection was embedded with a different set of configurations: {collection_ep}.",
            file=sys.stderr,
        )
        print("The result may be inaccurate.", file=sys.stderr)
    return True
