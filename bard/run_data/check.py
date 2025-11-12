from utils.drawing import *
import json
import os
import re


# 训练数据地址
data_path = ["/Users/bardanyu/Desktop/code/Simens_sft/data/holes_qwen3_siemens02_1000/view.json","/Users/bardanyu/Desktop/code/Simens_sft/data/holes_qwen3_siemens02_1000/view_ex.json"]

# 图片保存地址
img_save_path = ["/Users/bardanyu/Desktop/code/Simens_sft/data/holes_qwen3_siemens02_1000/check_train_data","/Users/bardanyu/Desktop/code/Simens_sft/data/holes_qwen3_siemens02_1000/check_train_data_ex"]

for i in img_save_path:
    if not os.path.exists(i):
        os.makedirs(i)

def extract_json_blocks(text: str) -> List[str]:
    pattern = re.compile(r'```json\s*([\s\S]*?)```', re.MULTILINE)
    return eval([m.group(1).strip() for m in pattern.finditer(text)][0])

for n,dp in enumerate(data_path):
    with open(dp,"r",encoding="utf-8") as f:
        trains = json.load(f)
    result = {}
    for i in trains:
        image_path = os.path.join(os.path.dirname(dp),i["images"][0])
        resp = i["messages"][-1]["content"]
        result[image_path] = extract_json_blocks(resp)
        bbox = {}
        for item in result[image_path]:
            if item["category"] in bbox:
                bbox[item["category"]].append(item["bbox_2d"])
            else:
                bbox[item["category"]] = [item["bbox_2d"]] if item["bbox_2d"] else []
        draw_bboxes_pil(image_path,bbox ,os.path.join(img_save_path[n],os.path.basename(image_path)),mode="qwen3")

