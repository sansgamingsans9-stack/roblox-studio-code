#!/usr/bin/env python3
"""Builds build/DeformableSnow.rbxmx from src/DeformableSnow.

The model is a single Folder you drop into ReplicatedStorage:
  * *.luau                -> ModuleScript
  * *.client.luau         -> Script with RunContext = Client
  * *.server.luau         -> Script with RunContext = Server
Usage: python3 tools/build_rbxmx.py
"""
import pathlib
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "DeformableSnow"
OUT = ROOT / "build" / "DeformableSnow.rbxmx"

# modules first (in dependency order, purely cosmetic in the Explorer), then the two entry scripts
ORDER = ["Config", "Shapes", "SnowField", "StampCodec", "ChunkMesh", "SnowClient", "SnowServer"]
RUN_CONTEXT = {"client": 2, "server": 1}  # Enum.RunContext values


def ref() -> str:
    return "RBX" + uuid.uuid4().hex.upper()


def cdata(text: str) -> str:
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def item(cls: str, name: str, source: str, run_context: int | None = None) -> str:
    props = [f'\t\t\t\t<string name="Name">{name}</string>']
    if run_context is not None:
        props.append(f'\t\t\t\t<token name="RunContext">{run_context}</token>')
        props.append('\t\t\t\t<bool name="Disabled">false</bool>')
    props.append(f'\t\t\t\t<ProtectedString name="Source">{cdata(source)}</ProtectedString>')
    return (
        f'\t\t<Item class="{cls}" referent="{ref()}">\n'
        "\t\t\t<Properties>\n" + "\n".join(props) + "\n\t\t\t</Properties>\n"
        "\t\t</Item>\n"
    )


def main() -> None:
    items = []
    for name in ORDER:
        items.append(item("ModuleScript", name, (SRC / f"{name}.luau").read_text()))
    for path in sorted(SRC.glob("*.*.luau")):
        name, kind, _ = path.name.split(".")
        items.append(item("Script", name, path.read_text(), RUN_CONTEXT[kind]))

    leftovers = {p.stem for p in SRC.glob("*.luau") if p.name.count(".") == 1} - set(ORDER)
    if leftovers:
        raise SystemExit(f"modules missing from ORDER: {sorted(leftovers)}")

    xml = (
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n'
        f'\t<Item class="Folder" referent="{ref()}">\n'
        "\t\t<Properties>\n"
        '\t\t\t<string name="Name">DeformableSnow</string>\n'
        "\t\t</Properties>\n" + "".join(items) + "\t</Item>\n</roblox>\n"
    )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(xml)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(xml) // 1024} KB, {len(items)} scripts)")


if __name__ == "__main__":
    main()
