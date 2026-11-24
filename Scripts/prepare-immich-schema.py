#!/usr/bin/env python3
"""从固定官方Schema准备客户端生成源；保留智能搜索实际使用的旧分页响应。"""

import json
import sys
from copy import deepcopy
from pathlib import Path
from typing import Dict, List, Union, cast

JsonValue = Union[None, bool, int, float, str, List["JsonValue"], Dict[str, "JsonValue"]]
JsonObject = Dict[str, JsonValue]


def prepare(document: JsonObject, extensions: JsonObject) -> JsonObject:
    """原位准备已固定来源的OpenAPI JSON并返回同一文档。

    Args:
        document: 完整官方OpenAPI对象；调用方必须提供components.schemas。
            本函数修改其中metadata请求和用户配置字段，保留其他Schema。
        extensions: 仓库固定的搜索扩展Schema输入，不修改；只补入明确使用的字段及依赖。
    Returns:
        同一可变文档，供Swift生成器读取；智能搜索nextPage保留。
    Raises:
        KeyError: 固定源缺少预期Schema或属性。
        ValueError: 被移除的旧metadata字段仍标记为必填。
    """
    components = cast(JsonObject, document["components"])
    schemas = cast(Dict[str, JsonObject], components["schemas"])
    # metadata只用filter/orderBy/cursor；smart的旧式字段属于另一DTO，不能一起删除。
    schema = schemas["MetadataSearchDto"]
    properties = cast(Dict[str, JsonObject], schema["properties"])
    for name in list(properties):
        if properties[name].get("deprecated"):
            if name in cast(List[str], schema.get("required", [])):
                raise ValueError(f"Cannot remove required search property: {name}")
            del properties[name]
    # 搜索响应同时保留nextCursor和nextPage；后者仍被官方旧式smart分页使用。
    # 配置解码继续只依赖当前客户端真正消费的字段，不扩大本次Schema刷新范围。
    config = schemas["UserConfigDto"]
    config_properties = cast(JsonObject, config["properties"])
    config["properties"] = {name: config_properties[name] for name in ("map", "server")}
    config["required"] = ["map"]
    server = schemas["UserConfigServerDto"]
    server_properties = cast(JsonObject, server["properties"])
    server["properties"] = {"externalDomain": server_properties["externalDomain"]}
    server.pop("required", None)
    # 仅扩展请求过滤节点，不刷新原有媒体/登录等响应Schema，保持既有解码范围。
    extension_schemas = cast(Dict[str, JsonObject], extensions["schemas"])
    for name in ("SearchFilter", "SearchFilterBranch"):
        target = cast(JsonObject, schemas[name]["properties"])
        additions = cast(JsonObject, extension_schemas[name]["properties"])
        target.update(deepcopy(additions))
    for name in ("MediaOrientationFilter", "SearchOrientation"):
        schemas[name] = deepcopy(extension_schemas[name])
    return document


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        document: JsonObject = json.load(source)
    extension_path = Path(__file__).resolve().parent.parent / "Packages/ImmichAPI/search-extensions.json"
    with extension_path.open(encoding="utf-8") as source:
        extensions: JsonObject = json.load(source)
    prepare(document, extensions)
    with open(sys.argv[2], "w", encoding="utf-8") as destination:
        json.dump(document, destination, indent=2, ensure_ascii=False)
        destination.write("\n")
