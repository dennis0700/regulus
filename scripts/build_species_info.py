"""从 SuperPicky 的名录与参考库生成 Regulus 的 species_info.json（仅依赖标准库）。

数据只放在本机的模型目录里，不纳入 git：eBird、IUCN 等数据各有使用条款。

每个鸟种（下标即 BirdTrace 鸟种库类别号）一条：
    zh       《中国鸟类名录》2026 版的中文名，名录里没有时用模型自带的中文名
    en, sci  英文名、学名（模型自带）
    inChina  是否对上了中国名录 2026
    order, family, genus  目、科、属的中文名（IOC 15.1，按学名匹配，对不上为空串）
    iucn     IUCN 红色名录等级（LC、NT、VU、EN、CR 等），没有数据时省略
    rarity   GBIF 全球罕见度 0–100（一位小数），没有数据时省略

结果写到 --models 目录下的 species_info.json。

用法：
    python3 scripts/build_species_info.py --superpicky ../SuperPicky
"""

import argparse
import json
import logging
import sqlite3
from pathlib import Path

LOGGER = logging.getLogger(__name__)
CHINA_2026 = "ChinaBirds.ZS.2026"
IOC = "IOC 15.1"
DEFAULT_MODELS = Path.home() / "Library/Application Support/Regulus/models/birdtrace"


def version_id(db: sqlite3.Connection, name: str) -> int:
    """名录版本号。

    Args:
        db: birdname.db 连接。
        name: versions 表里的版本名。

    Returns:
        版本号。

    Raises:
        LookupError: 没有这个版本。

    """
    row = db.execute("SELECT version_id FROM versions WHERE version_name = ?", (name,)).fetchone()
    if row is None:
        raise LookupError(f"checklist version not found: {name}")
    return int(row[0])


def checklist(
    birdname: Path,
) -> tuple[list[tuple[str, str]], dict[str, str], dict[str, tuple[str, str, str]]]:
    """读取中国名录 2026 的（中文名, 学名）、IOC 的中文名 → 学名、IOC 的目科属。

    Args:
        birdname: SuperPicky 的 ioc/birdname.db。

    Returns:
        (中国名录的（中文名, 学名）, IOC 中文名 → 学名, IOC 学名 → (目, 科, 属))。

    """
    db = sqlite3.connect(birdname)
    try:
        china = version_id(db, CHINA_2026)
        ioc = version_id(db, IOC)
        # 2026 版把学名存在 english_name 一列里 / the 2026 edition keeps the scientific name in english_name
        china_rows = [
            (zh.strip(), sci.strip())
            for zh, sci in db.execute("SELECT chinese_name, english_name FROM birds WHERE version_id = ?", (china,))
            if zh and sci
        ]
        ioc_rows = db.execute(
            "SELECT latin_name, chinese_name, order_zh, family_zh, genus_zh FROM birds WHERE version_id = ?", (ioc,)
        ).fetchall()
    finally:
        db.close()
    taxonomy = {sci.strip(): (order or "", family or "", genus or "") for sci, _, order, family, genus in ioc_rows if sci}
    ioc_by_zh = {zh.strip(): sci.strip() for sci, zh, *_ in ioc_rows if sci and zh}
    return china_rows, ioc_by_zh, taxonomy


def match_names(china: list[tuple[str, str]], targets: set[str], ioc_by_zh: dict[str, str]) -> dict[str, str]:
    """把中国名录的（中文名, 学名）对到模型的学名上。

    2026 版有些鸟还用旧学名（如领鸺鹠 Glaucidium brodiei，模型和 IOC 为 Taenioptynx brodiei）。
    依次尝试：学名相同；中文名在 IOC 里对应的学名；对前两步都没对上的条目，套用第二步
    发现的属名变更（如 Ixobrychus → Botaurus）后再按学名对，已对上的学名不覆盖。

    Args:
        china: 中国名录的（中文名, 学名）。
        targets: 要对上的学名（模型的学名）。
        ioc_by_zh: IOC 的中文名 → 学名。

    Returns:
        模型学名 → 中国名录中文名。

    """
    names: dict[str, str] = {}
    renamed_genera: dict[str, str] = {}
    pending: list[tuple[str, str]] = []
    for zh, sci in china:
        if sci in targets:
            names[sci] = zh
        elif ioc_by_zh.get(zh) in targets:
            new = ioc_by_zh[zh]
            names[new] = zh
            renamed_genera.setdefault(sci.split(" ")[0], new.split(" ")[0])
        else:
            pending.append((zh, sci))
    for zh, sci in pending:
        genus, _, epithet = sci.partition(" ")
        new = f"{renamed_genera.get(genus, genus)} {epithet}"
        if new in targets and new not in names:
            names[new] = zh
    return names


def reference(path: Path) -> tuple[dict[int, str], dict[int, float]]:
    """按鸟种库类别号读取 IUCN 等级和 GBIF 罕见度。

    Args:
        path: SuperPicky 的 birdid/data/bird_reference.sqlite。

    Returns:
        (类别号 → IUCN 等级, 类别号 → 罕见度（保留一位小数）)。

    """
    db = sqlite3.connect(path)
    try:
        iucn = {
            int(cid): code
            for cid, code in db.execute("SELECT model_class_id, iucn_category FROM avilist_map")
            if cid is not None and code
        }
        rarity = {
            int(cid): round(float(score), 1)
            for cid, score in db.execute("SELECT model_class_id, gbif_rarity_100 FROM gbif_rarity_100")
            if cid is not None and score is not None
        }
        return iucn, rarity
    finally:
        db.close()


def build(superpicky: Path, models: Path) -> list[dict[str, object]]:
    """合并成与 species_names.json 下标一致的列表。

    Args:
        superpicky: SuperPicky 仓库目录。
        models: Regulus 的 models/birdtrace 目录（读取 species_names.json）。

    Returns:
        每个鸟种一条记录。

    Raises:
        LookupError: birdname.db 里缺少所需的名录版本。

    """
    species = json.loads((models / "species_names.json").read_text(encoding="utf-8"))
    china, ioc_by_zh, taxonomy = checklist(superpicky / "ioc/birdname.db")
    names = match_names(china, {item.get("sci", "") for item in species}, ioc_by_zh)
    iucn, rarity = reference(superpicky / "birdid/data/bird_reference.sqlite")
    entries: list[dict[str, object]] = []
    for index, item in enumerate(species):
        sci = item.get("sci", "")
        order, family, genus = taxonomy.get(sci, ("", "", ""))
        entry: dict[str, object] = {
            "zh": names.get(sci) or item.get("zh", ""),
            "en": item.get("en", ""),
            "sci": sci,
            "inChina": sci in names,
            "order": order,
            "family": family,
            "genus": genus,
        }
        if index in iucn:
            entry["iucn"] = iucn[index]
        if index in rarity:
            entry["rarity"] = rarity[index]
        entries.append(entry)
    LOGGER.info(
        "species=%d china2026=%d taxonomy=%d iucn=%d rarity=%d",
        len(entries),
        sum(1 for e in entries if e["inChina"]),
        sum(1 for e in entries if e["order"]),
        sum(1 for e in entries if "iucn" in e),
        sum(1 for e in entries if "rarity" in e),
    )
    return entries


def main() -> None:
    """命令行入口：生成并写出 <models>/species_info.json。"""
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--superpicky", type=Path, required=True, help="SuperPicky 仓库目录")
    parser.add_argument("--models", type=Path, default=DEFAULT_MODELS, help="Regulus 的 models/birdtrace 目录")
    args = parser.parse_args()
    entries = build(args.superpicky, args.models)
    out = args.models / "species_info.json"
    out.write_text(json.dumps(entries, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    LOGGER.info("wrote %s (%d bytes)", out, out.stat().st_size)


if __name__ == "__main__":
    main()
