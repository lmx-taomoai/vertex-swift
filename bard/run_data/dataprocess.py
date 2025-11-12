import os
from utils import labelstudio_trans,draw_box_pil,smart_resize,convert_to_qwen25vl_format,convert_to_qwen3vl_format
import json
import copy
from PIL import Image, ImageDraw
import re





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

def extract_text(s):
    """处理labelstudio导出的训练数据中 size 部分"""
    pattern = re.compile(r'[a-zA-Z0-9*.]')  # 含义：数字 或 * 或 m
    tokens = pattern.findall(s.lower())
    return "".join(tokens)  # ['123', '*', '456', 'm', '789']

def rotate_box_90_cw(path,box,mode = "qwen2"):
    """
    图片顺时针旋转90度后bbox坐标
    """
    x1, y1, x2, y2 = box
    img = Image.open(path)
    img_w,img_h = img.size
    if mode == "qwen3":
        x1 = round(x1 / 1000 * img_w)
        y1 = round(y1 / 1000 * img_h)
        x2 = round(x2 / 1000 * img_w)
        y2 = round(y2 / 1000 * img_h)
        new_x1 = img_h - y2
        new_y1 = x1
        new_x2 = img_h - y1
        new_y2 = x2
        new_w = img_h
        new_h = img_w
        x1 = round(new_x1 / new_w * 1000)
        y1 = round(new_y1 / new_h * 1000)
        x2 = round(new_x2 / new_w * 1000)
        y2 = round(new_y2 / new_h * 1000)
        return [x1,y1,x2,y2]
    return [img_h - y2, x1, img_h - y1, x2]

def prepare_data(dataset_path,save_dir):
    with open(dataset_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    img_list = []
    for i in data:
        img_url = i['data']['image']
        img_list.append(img_url)
    label_holes = []
    label_views = []
    for ni, i in enumerate(data):
        anns = i["annotations"]
        views_result = anns[1]
        holes_result = anns[0]
        view_sample = copy.deepcopy(i)
        view_sample["annotations"] = [views_result]
        label_views.append(view_sample)
        hole_sample = copy.deepcopy(i)
        hole_sample["annotations"] = [holes_result]
        label_holes.append(hole_sample)
    with open(os.path.join(save_dir,"label_holes.json"), "w", encoding="utf-8") as f:
        json.dump(label_holes, f, ensure_ascii=False, indent=4)
    with open(os.path.join(save_dir,"label_views.json"), "w", encoding="utf-8") as f:
        json.dump(label_views, f, ensure_ascii=False, indent=4)
    # 取展开图标注
    views = labelstudio_trans(os.path.join(save_dir,"label_views.json"))
    # 取孔标注
    holes = labelstudio_trans(os.path.join(save_dir,"label_holes.json"))
    # 公共keys
    common_keys = set(views.keys()) & set(holes.keys())

    download_url_list = []
    for i in common_keys:
        # 判断是否含有展开图以及孔size是否存在
        if [x for x in views[i] if x[3] == "ExpandView"] and len(holes[i]) == len([x for x in holes[i] if x[4]]):
            download_url_list.append(i)
        else:
            print(i,"not_")
    return views , holes , download_url_list

def get_feats(download_url_list,views,holes,save_dir):
    # 切展开图,resize图片并调整孔坐标，调整两次，1，展开图对应坐标 2 resize后的坐标
    if not os.path.exists(os.path.join(save_dir,"train_data")):
        os.makedirs(os.path.join(save_dir,"train_data"))
    result = {}
    for i in download_url_list:
        img_name = os.path.basename(i)
        img_path = os.path.join(save_dir,"images",img_name)
        view = [ x for x in views[i] if x[3] == "ExpandView"][0]
        hole = holes[i]
        save_path = os.path.join(save_dir,"train_data",img_name)
        img = Image.open(img_path).crop(view[0])
        # 展开图部分宽高
        orig_width,orig_height = img.size
        # 图片resize后保存
        new_height,new_width= smart_resize(orig_height, orig_width,factor=32,min_pixels=2*2*32*32,max_pixels=32 * 32 * 4 * 2560)
        if (orig_height, orig_width) != (new_height, new_width):
            img = img.resize((new_width,new_height))
        img.save(save_path, quality=100)
        # 孔标注结果依次转换
        feats = []
        for j in hole:
            # 判断孔是否在展开图上
            if j[0][0] >= view[0][0] and j[0][2] <= view[0][2] and j[0][1] >= view[0][1] and j[0][3] <= view[0][3]:
                bbox = [j[0][0] - view[0][0],j[0][1]- view[0][1],j[0][2]- view[0][0],j[0][3]- view[0][1]]
                bbox = convert_to_qwen3vl_format(bbox, orig_height, orig_width,factor=32,min_pixels=2*2*32*32,max_pixels=32 * 32 * 4 * 2560)
                feats.append([bbox,j[3],j[4][0]])
        result[i] = feats
    return result

def main(result,save_dir):
    # 转化为训练数据格式
    trains_in = []
    trains_in_ex = []
    label_cnt = {}
    train_data_ex_dir = os.path.join(save_dir,"train_data_ex")
    if not os.path.exists(train_data_ex_dir):
        os.makedirs(train_data_ex_dir)
    for key,value in result.items():
        img_mark = f"train_data/{os.path.basename(key)}"
        img_ex_mark = f"train_data_ex/{os.path.basename(key)}"
        img_path = os.path.join(save_dir,"train_data",os.path.basename(key))
        # 进一步增强 旋转图片
        img = Image.open( img_path ).convert('RGB')
        img_rot = img.rotate(-90, expand=True, fillcolor=(0, 0, 0))
        img_rot.save(os.path.join( train_data_ex_dir ,os.path.basename(key)))
        # 原图片qa对
        msg = {}
        for i in value:
            if i[1] not in label_cnt:
                label_cnt[i[1]] = 0
            else:
                label_cnt[i[1]] += 1
            if i[1].replace("方孔","矩形孔") not in msg:
                msg[i[1].replace("方孔","矩形孔")] = []
            msg[i[1].replace("方孔","矩形孔")].append({"bbox_2d":i[0],"size":extract_text(i[2]).strip()})
        msga = list(msg.keys())
        for k in [x for x in ["圆孔" ,"腰孔" ,"矩形孔" ,"螺纹孔"] if x not in msga]:
            msg[k] = [{}]
        msg_ = []
        for i in ["圆孔" ,"腰孔" ,"矩形孔" ,"螺纹孔"]:
           msg_ +=  [ {"category":i,"bbox_2d":x.get("bbox_2d",[]),"size":x.get("size","")} for x in msg[i] ]
        messages = [
              {
                "content": prompts,
                "role": "user"
              },
              {
                "content": f"```json\n{json.dumps(msg_, indent=2,ensure_ascii=False)}\n```" ,
                "role": "assistant"
              }
            ]
        trains_in.append({"messages":messages,"images":[img_mark]})

        # 旋转后图片qa
        value_ = [[list(rotate_box_90_cw(img_path,x[0],mode="qwen3")),x[1],x[2]] for x in value]
        msg = {}
        for i in value_:
            if i[1].replace("方孔","矩形孔") not in msg:
                msg[i[1].replace("方孔","矩形孔")] = []
            msg[i[1].replace("方孔","矩形孔")].append({"bbox_2d":i[0],"size":extract_text(i[2]).strip()})
        msga = list(msg.keys())
        for k in [x for x in ["圆孔" ,"腰孔" ,"矩形孔" ,"螺纹孔"] if x not in msga]:
            msg[k] = [{}]
        msg_ = []
        for i in ["圆孔" ,"腰孔" ,"矩形孔" ,"螺纹孔"]:
           msg_ +=  [ {"category":i,"bbox_2d":x.get("bbox_2d",[]),"size":x.get("size","")} for x in msg[i] ]
        messages = [
            {
                "content": prompts,
                "role": "user"
            },
            {
                "content": f"```json\n{json.dumps(msg_, indent=2, ensure_ascii=False)}\n```",
                "role": "assistant"
            }
        ]
        trains_in_ex.append({"messages":messages,"images":[img_ex_mark]})
    os.path.join(save_dir,"view.json")
    with open(os.path.join(save_dir,"view.json"), 'w', encoding='utf-8') as f:
        json.dump(trains_in, f, ensure_ascii=False, indent=2)
    with open(os.path.join(save_dir,"view_ex.json"), 'w', encoding='utf-8') as f:
        json.dump(trains_in_ex, f, ensure_ascii=False, indent=2)

if __name__ == "__main__":
    # # 数据集地址
    # dataset_path = "/Users/bardanyu/Desktop/code/Simens_sft/dataset/siemens02-1000-2019-all-holes-mainview-expandview-train-20251024.json"
    # # 结果保存地址
    # save_dir = "/Users/bardanyu/Desktop/code/Simens_sft/data/holes_qwen3_siemens02_1000"
    # mode = "dataprocess"
    # views, holes, download_url_list = prepare_data(dataset_path, save_dir)
    # feats = get_feats(download_url_list,views,holes,save_dir)
    # main(feats, save_dir)


    # 数据集地址
    dataset_path = "/dataset/siemens02-1000-2019-all-holes-mainview-expandview-test-20251024.json"
    # 结果保存地址
    save_dir = "/data/holes_qwen3_siemens02_1000_test"

    views, holes, download_url_list = prepare_data(dataset_path, save_dir)
    feats = get_feats(download_url_list,views,holes,save_dir)
    main(feats, save_dir)






