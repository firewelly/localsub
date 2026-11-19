#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按清单串行下载 Whisper ggml 与日译中 GGUF 模型（断点续传 + sha256 校验）。

用法（在本机 macOS 准备机）:
    python3 models/download_models.py            # 全部任务（已完成的自动跳过）
    python3 models/download_models.py large-v3   # 只跑名字包含 large-v3 的任务

网络: HuggingFace 直连不可用，全部经 SOCKS5 代理 socks5h://127.0.0.1:1080。
依赖: requests + PySocks (pip install pysocks)。
"""
import hashlib
import os
import shutil
import sys
import time
from urllib.parse import quote

import requests

PROXY = {
    "http": "socks5h://127.0.0.1:1080",
    "https": "socks5h://127.0.0.1:1080",
}
BASE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(BASE, "download.log")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) dsh-model-prep/1.0"

# size / sha256 均取自 HuggingFace API tree?recursive=1 的 size / lfs.oid（2026-11-15 核实）
TASKS = [
    dict(
        name="silero-vad",
        repo="ggml-org/silero-v5.1.2",
        file="ggml-silero-v5.1.2.bin",
        dest="whisper/ggml-silero-v5.1.2.bin",
        size=885098,
        sha256="29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
        note="whisper.cpp VAD（可选，语音端点检测）",
    ),
    dict(
        name="large-v3",
        repo="ggerganov/whisper.cpp",
        file="ggml-large-v3.bin",
        dest="whisper/ggml-large-v3.bin",
        size=3095033483,
        sha256="64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        note="日语听写主模型 (Whisper large-v3)",
    ),
    dict(
        name="large-v3-turbo",
        repo="ggerganov/whisper.cpp",
        file="ggml-large-v3-turbo.bin",
        dest="whisper/ggml-large-v3-turbo.bin",
        size=1624555275,
        sha256="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        note="日语听写对照模型 (large-v3-turbo)",
    ),
    dict(
        name="sakura-galtransl-7b-v3.7",
        repo="SakuraLLM/Sakura-GalTransl-7B-v3.7",
        file="Sakura-Galtransl-7B-v3.7.gguf",
        dest="translation/Sakura-Galtransl-7B-v3.7.gguf",
        size=6254196608,
        sha256="e1ae01b1735cfdcd00a3c7e2e5e06ff3a2756cc0d7592f4b4f5945638a8629f2",
        note="日译中专训主模型 Q6_K (Sakura-GalTransl v3.7)",
    ),
]


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def free_bytes():
    usage = shutil.disk_usage(os.path.dirname(os.path.abspath(__file__)))
    return usage.free


def download(task):
    url = f"https://huggingface.co/{task['repo']}/resolve/main/{quote(task['file'])}?download=true"
    dst = os.path.join(BASE, task["dest"])
    part = dst + ".part"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    expected = task["size"]
    log(f"== {task['name']}: {url}")

    if os.path.exists(dst):
        got = os.path.getsize(dst)
        log(f"   已存在 {task['dest']} ({got:,} B)，校验 sha256 ...")
        digest = sha256_file(dst)
        if got == expected and digest == task["sha256"]:
            log(f"   OK 已完整且校验通过，跳过：{task['dest']}")
            return True
        log(f"   FAIL 现有文件不符 (size={got:,}/{expected:,}, sha256={digest})，删除重下")
        os.remove(dst)

    if os.path.exists(part):
        log(f"   发现 .part 续传点 {os.path.getsize(part):,} B")
    if free_bytes() < expected * 1.1:
        log(f"   FAIL 磁盘空间不足：剩 {free_bytes()/1e9:.1f} GB，需要 {expected*1.1/1e9:.1f} GB")
        return False

    for attempt in range(1, 21):
        pos = os.path.getsize(part) if os.path.exists(part) else 0
        headers = {"User-Agent": UA}
        if pos:
            headers["Range"] = f"bytes={pos}-"
        try:
            with requests.Session() as sess:
                sess.proxies = PROXY
                sess.trust_env = False
                r = sess.get(url, headers=headers, stream=True, timeout=(20, 90), allow_redirects=True)
                if r.status_code == 416:
                    log("   HTTP 416，视作已下满")
                    break
                if r.status_code not in (200, 206):
                    log(f"   FAIL attempt {attempt}: HTTP {r.status_code}，15s 后重试")
                    time.sleep(15)
                    continue
                if pos and r.status_code == 200:
                    log("   服务器忽略了 Range，从头下载")
                    pos = 0
                mode = "ab" if pos else "wb"
                written = pos
                last_log = time.time()
                last_bytes = written
                with open(part, mode) as f:
                    for chunk in r.iter_content(chunk_size=1 << 20):
                        if not chunk:
                            continue
                        f.write(chunk)
                        written += len(chunk)
                        now = time.time()
                        if now - last_log >= 10 or written >= expected:
                            speed = (written - last_bytes) / max(now - last_log, 0.01) / 1e6
                            pct = 100.0 * written / expected
                            eta = (expected - written) / max(speed * 1e6, 1)
                            log(f"   {pct:5.1f}%  {written/1e9:.3f}/{expected/1e9:.3f} GB  "
                                f"{speed:.2f} MB/s  ETA {eta/60:.1f} min")
                            last_log = now
                            last_bytes = written
            break
        except Exception as e:  # noqa: BLE001
            log(f"   FAIL attempt {attempt}: {type(e).__name__}: {e}，10s 后续传")
            time.sleep(10)

    got = os.path.getsize(part) if os.path.exists(part) else 0
    if got != expected:
        log(f"   FAIL 大小不符：{got:,} != {expected:,}（保留 .part 供续传）")
        return False
    log("   下载完成，计算 sha256 ...")
    digest = sha256_file(part)
    if digest != task["sha256"]:
        log(f"   FAIL sha256 不符：{digest} != {task['sha256']}")
        bad = part + ".bad"
        os.replace(part, bad)
        log(f"   已把坏文件移到 {os.path.basename(bad)}，需人工复下")
        return False
    os.replace(part, dst)
    log(f"   OK 校验通过：{task['dest']} ({expected:,} B) sha256={digest}")
    return True


def main():
    want = sys.argv[1:]
    tasks = [t for t in TASKS if not want or any(w in t["name"] for w in want)]
    log(f"### 开始：{len(tasks)} 个任务，代理={PROXY['https']}")
    ok = True
    for t in tasks:
        try:
            ok = download(t) and ok
        except KeyboardInterrupt:
            log("!! 被中断")
            return 130
    log(f"### 结束：{'全部成功' if ok else '存在失败，见上方日志'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
