import json
import os
import socket

import tabulate
from chromadb.api.types import IncludeEnum

from vectorcode.cli_utils import Config
from vectorcode.common import get_client


async def ls(configs: Config) -> int:
    client = await get_client(configs)
    result: list[dict] = []
    collections = await client.list_collections()
    for collection_name in collections:
        collection = await client.get_collection(collection_name)
        meta = collection.metadata
        if meta is None:
            continue
        if meta.get("created-by") != "VectorCode":
            continue
        if meta.get("username") not in (
            os.environ.get("USER"),
            os.environ.get("USERNAME"),
            "DEFAULT_USER",
        ):
            continue
        if meta.get("hostname") != socket.gethostname():
            continue
        document_meta = await collection.get(include=[IncludeEnum.metadatas])
        unique_files = set(
            i.get("path") for i in document_meta["metadatas"] if i is not None
        )
        result.append(
            {
                "project-root": meta["path"],
                "user": meta.get("username"),
                "hostname": socket.gethostname(),
                "collection_name": collection_name,
                "size": await collection.count(),
                "embedding_function": meta["embedding_function"],
                "num_files": len(unique_files),
            }
        )

    if configs.pipe:
        print(json.dumps(result))
    else:
        table = []
        for meta in result:
            project_root = meta["project-root"]
            if os.environ.get("HOME"):
                project_root = project_root.replace(os.environ["HOME"], "~")
            row = [
                project_root,
                meta["size"],
                meta["num_files"],
                meta["embedding_function"],
            ]
            table.append(row)
        print(
            tabulate.tabulate(
                table,
                headers=[
                    "Project Root",
                    "Collection Size",
                    "Number of Files",
                    "Embedding Function",
                ],
            )
        )
    return 0
