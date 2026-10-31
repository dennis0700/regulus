"""按 scripts/samples_manifest.json 下载 RAW / JPEG 样片到 samples/ 并校验哈希。

用法（在 regulus/ 根目录）::

    python3 scripts/fetch_samples.py           # 下载缺失文件，已有的只校验
    python3 scripts/fetch_samples.py --verify  # 仅校验

首次下载成功后会把 sha256 回写到 manifest，之后的下载与 --verify 都按它校验。
"""

import argparse
import json
import logging
import sys
import urllib.error
from pathlib import Path

from download import ChecksumError, fetch, file_digest, verify

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "scripts" / "samples_manifest.json"
SAMPLES = REPO_ROOT / "samples"


def expected_hashes(entry: dict[str, str | None]) -> dict[str, str]:
    """从 manifest 条目取出已知哈希。

    Args:
        entry: manifest 中的一个样片条目。

    Returns:
        算法名到哈希值的映射（只包含非空值）。
    """
    return {name: value for name in ("sha1", "sha256") if (value := entry.get(name))}


def run(verify_only: bool) -> list[str]:
    """下载或校验全部样片，单个失败不影响其余文件；新算出的 sha256 回写 manifest。

    Args:
        verify_only: 为 True 时只校验已存在的文件，缺失或无 sha256 都算失败。

    Returns:
        失败条目的描述列表；为空表示全部成功。
    """
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    failures: list[str] = []
    changed = False
    for entry in manifest["raw"] + manifest["jpeg"]:
        dest = SAMPLES / entry["file"]
        try:
            if verify_only:
                if not dest.exists() or not entry.get("sha256"):
                    raise FileNotFoundError(f"{dest} missing or sha256 not recorded")
                verify(dest, expected_hashes(entry))
            else:
                fetch(entry["url"], dest, expected_hashes(entry))
                if not entry.get("sha256"):
                    entry["sha256"] = file_digest(dest)
                    changed = True
        except (urllib.error.URLError, TimeoutError, ChecksumError, OSError) as error:
            logging.error("failed %s: %s", entry["file"], error)
            failures.append(f"{entry['file']}: {error}")
    if changed:
        text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
        MANIFEST.write_text(text, encoding="utf-8")
    return failures


def main() -> int:
    """命令行入口。

    Returns:
        进程退出码，0 表示全部成功。
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="only re-check hashes")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    failures = run(args.verify)
    for failure in failures:
        print(f"FAILED {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
