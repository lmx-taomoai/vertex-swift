from transformers import Qwen3VLForConditionalGeneration,Qwen2_5_VLForConditionalGeneration, AutoProcessor
import numpy as np
import math
from PIL import Image, ImageDraw, ImageFont
from typing import Dict, List, Tuple
import random
import re
from typing import List
import os


def extract_json_blocks(text: str) -> List[str]:
    """
    提取所有 ```json ... ``` 代码块中的内容。
    返回 List[str]，每个元素就是一个 JSON 字符串（可能跨行）。
    """
    pattern = re.compile(r'```json\s*([\s\S]*?)```', re.MULTILINE)
    return eval([m.group(1).strip() for m in pattern.finditer(text)][0])

def draw_bboxes_pil(
        img_path: str,
        bboxes_dict: Dict[str, List[List[int]]],
        save_path: str,
        box_width: int = 4,
        font_size: int = 28,                # ← 足够大
        color_map: Dict[str, Tuple[int, int, int]] =  {
    "圆孔": (255, 0, 0),    # 红色
    "腰孔": (255, 255, 0),    # 黄色
    "矩形孔": (0, 0, 255), # 蓝色
    "螺纹孔": (0, 255, 0),   # 绿色
},
mode:str = "qwen2"):
    img = Image.open(img_path).convert("RGB")
    img_w, img_h = img.size
    draw = ImageDraw.Draw(img, "RGBA")     # 支持透明
    try:
        font = ImageFont.truetype("segoeuib.ttf", font_size)
    except:
        try:
            font = ImageFont.truetype("DejaVuSans-Bold.ttf", font_size)
        except:
            font = ImageFont.truetype("Arial Bold", font_size)
    if color_map is None:
        color_map = {}
    for label in bboxes_dict.keys():
        if label not in color_map:
            color_map[label] = tuple(random.randint(0, 255) for _ in range(3))
    for label, boxes in bboxes_dict.items():
        color = color_map[label]
        for (x1, y1, x2, y2) in boxes:
            if mode == "qwen3":
                x1 = round(x1 / 1000 * img_w)
                y1 = round(y1 / 1000 * img_h)
                x2 = round(x2 / 1000 * img_w)
                y2 = round(y2 / 1000 * img_h)
            draw.rectangle([x1, y1, x2, y2], outline=color, width=box_width)
            left, top, right, bottom = draw.textbbox((0, 0), label, font=font)
            text_w = right - left
            text_h = bottom - top
            overlay = (0, 0, 0, 180)
            draw.rectangle([x1, y1 - text_h, x1 + text_w, y1], fill=overlay)
            draw.text((x1, y1 - text_h), label, fill=(255, 255, 255), font=font)
    img.save(save_path)
    print(f"saved -> {save_path}")

model_path = "/root/autodl-tmp/qwen3_swift/output/v2-20251029-141114/checkpoint-424-merged"

model = Qwen3VLForConditionalGeneration.from_pretrained(
    model_path, dtype="auto", device_map="auto"
)
processor = AutoProcessor.from_pretrained(model_path)




prompts = """<image>
任务：
在输入图纸或零件图像中，定位并分类所有孔实例，输出 JSON 列表。

1. 待检测类别（4 类）
  1.1 圆孔  (circle_hole)
  1.2 腰孔  (slot_hole)
  1.3 螺纹孔(thread_hole)
  1.4 矩形孔(rect_hole)

2. 几何定义与尺寸参数提取规则
  2.1 圆孔
      - 轮廓：闭合圆
      - 尺寸参数 D：直径，单位 mm，例 18 → "18mm"
  2.2 腰孔
      - 轮廓：形似椭圆，两平行直边 + 两对称半圆弧
      - 尺寸参数 W×L：直边间距 W，两圆弧中心距 L，单位 mm，例 14×30 → "14*30mm"
  2.3 螺纹孔
      - 轮廓：闭合圆（可见螺纹线且尺寸参数一定带有英文字母M）
      - 尺寸参数 M：标称直径，单位 mm，例 M18 → "18mm"
  2.4 矩形孔
      - 轮廓：四边形（含正方形）
      - 尺寸参数
        ‑ 正方形：边长 A，单位 mm，例 18 → "18mm"
        ‑ 长方形：长边x短边 LxW，单位 mm，例 20x14 → "20*14mm"

3. 输出格式（严格 JSON 列表，每对象字段如下）
  [
    {
      "category": "<类别中文标识>",
      "bbox": [x_min, y_min, x_max, y_max],   // 像素坐标，整数
      "size" : "<尺寸参数字符串>"
    },
    ...
  ]

4. 补充规则
  - 所有孔必须闭合可见。
  - 图纸中孔尺寸参数可能记录为N x size,N 表示同类型尺寸的孔的个数，请注意区分。
  - 无置信度阈值要求，但不得重复框。

请按以上指令执行检测并直接返回 JSON，勿附加解释。"""
def run(img_path,prompts):
    messages = [
        {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "image": img_path,
                },
                {"type": "text", "text": prompts},
            ],
        }
    ]
    inputs = processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        return_dict=True,
        return_tensors="pt"
    )
    inputs = inputs.to(model.device)
    generated_ids = model.generate(**inputs, max_new_tokens=1500)
    generated_ids_trimmed = [
        out_ids[len(in_ids) :] for in_ids, out_ids in zip(inputs.input_ids, generated_ids)
    ]
    output_text = processor.batch_decode(
        generated_ids_trimmed, skip_special_tokens=True, clean_up_tokenization_spaces=False
    )
    return output_text

test_img_path = "/root/autodl-tmp/qwen3_swift/test_img/train_data"
train_img_path = "/root/autodl-tmp/qwen3_swift/train_data"

result = {}
for image_path in [ os.path.join(test_img_path,x) for x in os.listdir(test_img_path)]:
    try:
        resp = run(image_path,prompts)
        resp = resp[0]
        result[image_path] = extract_json_blocks(resp)
        bbox = {}
        for item in result[image_path]:
            if item["category"] in bbox:
                bbox[item["category"]].append(item["bbox_2d"])
            else:
                bbox[item["category"]] = [item["bbox_2d"]] if item["bbox_2d"] else []
        draw_bboxes_pil(image_path,bbox ,os.path.join("/root/autodl-tmp/qwen3_swift/test_img_draw",os.path.basename(image_path)),mode="qwen3")
        with open(os.path.join("/root/autodl-tmp/qwen3_swift/test_img_draw",os.path.basename(image_path).replace(".png",".txt")),"w",encoding = "utf-8") as f:
            f.write(resp)
    except Exception as e:
        print(e)