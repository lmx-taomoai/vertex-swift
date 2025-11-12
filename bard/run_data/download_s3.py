import json
import os
import shlex
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

# ---------- 参数区 ----------
OUT_DIR   = "/Users/bardanyu/Desktop/code/Simens_sft/data/holes_qwen3_siemens02_1000_test/images_test"
MAX_WORKERS = 16
RETRY       = 3
# ----------------------------

os.makedirs(OUT_DIR, exist_ok=True)
lock = Lock()

def download_one(url: str) -> str:
    """单任务下载，失败自动重试"""
    cmd = f'aws s3 cp "{url}" {OUT_DIR}'
    for attempt in range(1, RETRY + 1):
        try:
            subprocess.check_call(shlex.split(cmd), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with lock:
                print(f"[OK] {url}")
            return url
        except subprocess.CalledProcessError:
            if attempt == RETRY:
                with lock:
                    print(f"[FAIL] {url}")
                    with open("failed.txt", "a", encoding="utf-8") as f:
                        f.write(url + "\n")
                return None
    return None

def main(urls):

    total = len(urls)
    print(f"共 {total} 张图片，开始下载（线程数={MAX_WORKERS}）...")
    succ = 0
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        future_map = {pool.submit(download_one, u): u for u in urls}
        for fut in as_completed(future_map):
            if fut.result() is not None:
                succ += 1

    print(f"全部完成！成功 {succ}/{total}，失败 {total-succ}（见 failed.txt）")

if __name__ == "__main__":
    urls = ['s3://im-drawing/datasets/siemens02-1000-2019/111_A7E0019018940_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/060_A7E0018076680_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/213_A7E0018050120_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/072_A7E0017574560_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/188_A7E0016824950_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/121_A7E0019023120_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/198_A7E0018049570_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/019_A7E0017567600_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/056_A7E0017573880_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/014_A7E0017567550_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/100_A7E0018603530_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/092_A7E0017577520_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/170_A7E0016820240_02_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/141_A7E0018045530_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/020_A7E0018074630_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/060_A7E0017573930_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/064_A7E0018076720_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/032_17569770_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/047_A7E0018075990_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/096_A7E0018603280_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/142_A7E0019025190_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/192_A7E0018049210_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/227_A7E0019061760_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/154_A7E0018046250_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/057_A7E0018076650_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/091_A7E0017577510_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/031_17569760_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/198_19060760_00_BL1_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/A7E0019661910_00F_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/079_A7E0017574780_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/252_19062310_00_BL1_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/075_A7E0017574690_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/142_A7E0018045540_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/004_A7E0018072490_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/220_19061470_01_BL1_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/095_A7E0018603270_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/161_A7E0018046510_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/015_A7E0018074300_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/112_A7E0019023000_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/132_A7E0018044550_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/220_A7E0017520150_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/101_A7E0017584850_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/090_18601310_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/217_A7E0017519100_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/149_A7E0019026390_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/19062980_01_BL1_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/119_A7E0018044150_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/054_A7E0018076580_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/138_A7E0019025140_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/188_A7E0018048980_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/033_A7E0017569780_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/225_A7E0017522550_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/212_A7E0018050110_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/128_A7E0019023790_02_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/062_A7E0017574040_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/118_A7E0019023090_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/061_A7E0017573940_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/028_A7E0017569660_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/167_A7E0018047460_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/223_A7E0018051100_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/050_A7E0018076540_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/213_A7E0017517390_01_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/145_A7E0018045570_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/369_A7E0019064930_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/162_A7E0018046920_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/025_A7E0018074760_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/046_A7E0018075980_00_page_001.png', 's3://im-drawing/datasets/siemens02-1000-2019/175_A7E0016820710_01_page_001.png']
    print(urls)
    main(urls)