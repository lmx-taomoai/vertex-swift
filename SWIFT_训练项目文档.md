# Swift 训练项目文档 - 工业图纸孔检测

## 项目概述

本项目基于 Swift 框架对 Qwen3-VL-4B-Instruct 多模态大模型进行微调，用于工业图纸中的孔检测和分类任务。项目实现了对图纸中4类孔型的自动识别、定位和尺寸提取。

---

## 1. 代码结构

### 1.1 核心文件组织

```
bard/
├── train.sh                    # 训练启动脚本
├── get_train_data.py          # 数据集构建脚本
├── eval.py                    # 模型评估脚本
├── export.sh                  # 模型导出脚本
├── view.json                  # 训练数据集（JSON格式）
├── view_ex.json               # 训练数据集扩展版（JSON格式）
├── view.jsonl                 # 训练数据集（JSONL格式）
├── view_ex.jsonl              # 训练数据集扩展版（JSONL格式）
├── train_data/                # 训练图片数据（449张PNG图片）
├── train_data_ex/             # 训练图片数据扩展版（449张PNG图片）
├── test_img/                  # 测试图片
└── test_img_draw/             # 测试结果可视化
```

### 1.2 模块功能说明

#### **train.sh** - 训练脚本
主要的训练启动脚本，配置所有训练参数并启动 Swift SFT 训练流程。

#### **get_train_data.py** - 数据预处理
将 JSON 格式的数据集转换为 JSONL 格式，适配 Swift 训练框架的数据输入要求。

#### **eval.py** - 评估推理
加载训练好的模型，对测试集进行推理，生成检测结果并可视化。

#### **export.sh** - 模型导出
将训练得到的 LoRA 适配器合并到基础模型中，导出完整模型。

---

## 2. 训练细节

### 2.1 模型配置

| 配置项 | 值 | 说明 |
|--------|-----|------|
| **基础模型** | Qwen3-VL-4B-Instruct | 通义千问多模态视觉语言模型 |
| **模型路径** | `/root/autodl-tmp/models/Qwen3-VL-4B-Instruct` | 预训练模型存储位置 |
| **模型类型** | qwen3_vl | Swift 框架中的模型标识 |

### 2.2 训练策略

#### **训练方法**
- **训练类型**: LoRA (Low-Rank Adaptation)
- **LoRA 秩**: 8
- **LoRA Alpha**: 32
- **目标模块**: all-linear（所有线性层）
- **冻结策略**: 
  - ViT 未冻结 (`freeze_vit: false`)
  - Aligner 未冻结 (`freeze_aligner: false`)

#### **数据处理**
- **数据集**: `view.jsonl` + `view_ex.jsonl`
- **验证集比例**: 1% (`split_dataset_ratio: 0.01`)
- **序列打包**: 启用 (`packing: true`)
- **最大序列长度**: 3000
- **数据加载进程数**: 4
- **DataLoader 工作进程**: 4
- **缓存加载**: 启用 (`load_from_cache_file: true`)
- **严格模式**: 启用 (`strict: true`)

### 2.3 训练超参数

```bash
训练轮数: 2 epochs
批次大小: 
  - 训练: 1 per device
  - 验证: 1 per device
学习率: 1e-4
优化器: AdamW (默认)
学习率调度: 
  - 预热比例: 5% (warmup_ratio: 0.05)
梯度累积步数: 2
```

### 2.4 计算资源配置

```bash
GPU 配置:
  - CUDA_VISIBLE_DEVICES: 0,1
  - 进程数/节点: 2 (NPROC_PER_NODE: 2)
  - 分布式策略: DeepSpeed Zero3

显存优化:
  - 梯度检查点: 启用 (gradient_checkpointing: true)
  - ViT 梯度检查点: 禁用 (vit_gradient_checkpointing: false)
  - CUDA 内存分配: expandable_segments模式
  - 数据类型: bfloat16
  - 注意力实现: flash_attention_2
  - 无填充模式: 启用 (padding_free: true)
```

### 2.5 图像处理配置

```bash
环境变量:
  - QWENVL_BBOX_FORMAT: 'new'           # 边界框格式
  - IMAGE_MAX_TOKEN_NUM: 1280           # 图像最大token数
  - VIDEO_MAX_TOKEN_NUM: 128            # 视频最大token数
  - FPS_MAX_FRAMES: 16                  # 视频最大帧数
```

### 2.6 训练监控

```bash
日志配置:
  - logging_steps: 5                    # 每5步打印一次日志
  - eval_steps: 100                     # 每100步评估一次
  - save_steps: 100                     # 每100步保存一次检查点
  - save_total_limit: 2                 # 最多保留2个检查点
  - output_dir: /root/autodl-tmp/qwen3_swift/output
```

---

## 3. 数据集构建

### 3.1 任务定义

本项目聚焦于**工业图纸孔检测与分类**任务，需要模型能够：
1. 识别并定位图纸中的孔
2. 分类孔的类型
3. 提取孔的尺寸参数
4. 输出标准化的 JSON 格式结果

### 3.2 检测类别（4类）

| 类别 | 英文标识 | 几何特征 | 尺寸参数示例 |
|------|----------|----------|--------------|
| **圆孔** | circle_hole | 闭合圆形轮廓 | "18mm" (直径D) |
| **腰孔** | slot_hole | 两平行直边 + 两对称半圆弧 | "14*30mm" (直边间距W × 圆弧中心距L) |
| **螺纹孔** | thread_hole | 闭合圆形，带螺纹线，尺寸带M标识 | "18mm" (M18标称直径) |
| **矩形孔** | rect_hole | 四边形（含正方形） | "18mm" (正方形边长) 或 "20*14mm" (长×宽) |

### 3.3 数据格式

#### **输入格式 (view.json / view_ex.json)**

```json
[
  {
    "messages": [
      {
        "content": "<image>\n任务：\n在输入图纸或零件图像中，定位并分类所有孔实例，输出 JSON 列表...",
        "role": "user"
      },
      {
        "content": "```json\n[\n  {\n    \"category\": \"圆孔\",\n    \"bbox_2d\": [116, 764, 140, 857],\n    \"size\": \"14mm\"\n  },\n  ...\n]\n```",
        "role": "assistant"
      }
    ],
    "images": [
      "train_data/113_A7E0018041240_00_page_001.png"
    ]
  }
]
```

#### **转换后格式 (view.jsonl / view_ex.jsonl)**

经 `get_train_data.py` 处理后，每行为一个独立的 JSON 对象：

```json
{"messages":[{"role":"user","content":"<image>\n任务：..."},{"role":"assistant","content":"```json\n[...]```"}],"images":["train_data/xxx.png"]}
```

### 3.4 标注规范

#### **边界框格式**
```json
"bbox_2d": [x_min, y_min, x_max, y_max]
```
- 坐标系：图像像素坐标
- 类型：整数
- 表示：左上角(x_min, y_min) 到 右下角(x_max, y_max)

#### **输出JSON结构**

```json
[
  {
    "category": "<类别中文标识>",      // "圆孔" | "腰孔" | "螺纹孔" | "矩形孔"
    "bbox_2d": [x_min, y_min, x_max, y_max],  // 像素坐标
    "size": "<尺寸参数字符串>"          // 如 "14mm", "14*20mm"
  }
]
```

### 3.5 数据集统计

| 数据集 | 图片数量 | 用途 |
|--------|----------|------|
| train_data | 449 | 基础训练集 |
| train_data_ex | 449 | 扩展训练集（数据增强/旋转） |
| test_img/train_data | 68 | 测试集 |

**总计**: 约 898 张训练图片 + 68 张测试图片

### 3.6 Prompt 设计

项目采用了详细的任务指令 Prompt，包含：

1. **任务描述**: 明确检测和分类目标
2. **类别定义**: 详细说明4类孔的几何特征
3. **尺寸提取规则**: 针对每类孔的参数提取方法
4. **输出格式**: 严格的 JSON Schema 定义
5. **补充规则**: 
   - 所有孔必须闭合可见
   - 注意区分 "N × size" 表示法（N是数量）
   - 无置信度要求，但不得重复检测

---

## 4. 评估与推理

### 4.1 评估流程 (eval.py)

#### **模型加载**

```python
model_path = "/root/autodl-tmp/qwen3_swift/output/v2-20251029-141114/checkpoint-424-merged"

model = Qwen3VLForConditionalGeneration.from_pretrained(
    model_path, 
    dtype="auto", 
    device_map="auto"
)
processor = AutoProcessor.from_pretrained(model_path)
```

#### **推理流程**

1. **构建对话消息**:
```python
messages = [
    {
        "role": "user",
        "content": [
            {"type": "image", "image": img_path},
            {"type": "text", "text": prompts}
        ]
    }
]
```

2. **应用对话模板**: 使用 `processor.apply_chat_template()` 处理
3. **模型生成**: 最大生成 1500 个 token
4. **后处理**: 提取 JSON 代码块

### 4.2 结果可视化

`eval.py` 包含完整的可视化功能：

```python
def draw_bboxes_pil(
    img_path: str,
    bboxes_dict: Dict[str, List[List[int]]],
    save_path: str,
    box_width: int = 4,
    font_size: int = 28,
    color_map: Dict[str, Tuple[int, int, int]] = {
        "圆孔": (255, 0, 0),     # 红色
        "腰孔": (255, 255, 0),   # 黄色
        "矩形孔": (0, 0, 255),   # 蓝色
        "螺纹孔": (0, 255, 0),   # 绿色
    },
    mode: str = "qwen3"
)
```

**可视化特性**:
- 不同类别使用不同颜色边框
- 在边界框上方显示类别标签
- 标签背景半透明，提升可读性
- 支持 qwen2/qwen3 两种坐标系转换

### 4.3 坐标系转换

```python
# Qwen3 使用归一化坐标 (0-1000)，需转换为像素坐标
if mode == "qwen3":
    x1 = round(x1 / 1000 * img_w)
    y1 = round(y1 / 1000 * img_h)
    x2 = round(x2 / 1000 * img_w)
    y2 = round(y2 / 1000 * img_h)
```

---

## 5. 模型导出

### 5.1 导出脚本 (export.sh)

```bash
CUDA_VISIBLE_DEVICES=0 \
swift export \
    --adapters /root/autodl-tmp/qwen3_swift/output/v2-20251029-141114/checkpoint-424 \
    --merge_lora true
```

### 5.2 导出流程

1. **输入**: LoRA adapter checkpoint
2. **处理**: 将 LoRA 权重合并到基础模型
3. **输出**: 完整的合并模型，可直接用于推理

**输出路径**: `{checkpoint_path}-merged/`

---

## 6. 项目依赖

### 6.1 核心框架
- **Swift**: ModelScope Swift 训练框架
- **Transformers**: Hugging Face Transformers
- **DeepSpeed**: 分布式训练加速

### 6.2 模型依赖
- **Qwen3VLForConditionalGeneration**: Qwen3 多模态模型
- **AutoProcessor**: 自动处理器加载

### 6.3 额外依赖
- **Flash Attention**: flash_attn-2.8.3+cu12torch2.8cxx11abiTRUE (预编译whl)
- **PIL**: 图像处理和可视化
- **numpy**: 数值计算

---

## 7. 运行指南

### 7.1 数据准备

```bash
# 1. 准备图片数据
cp your_images/* train_data/

# 2. 准备标注文件
# 编辑 view.json，按照规范格式添加标注

# 3. 转换为 JSONL 格式
python get_train_data.py
```

### 7.2 开始训练

```bash
# 直接运行训练脚本
bash train.sh
```

**注意事项**:
- 确保 GPU 可用且 CUDA 配置正确
- 确保基础模型路径正确
- 根据显存调整 batch_size 和梯度累积步数

### 7.3 模型评估

```bash
# 修改 eval.py 中的模型路径和测试图片路径
python eval.py
```

输出：
- `test_img_draw/*.png`: 可视化结果图片
- `test_img_draw/*.txt`: 模型原始输出文本

### 7.4 模型导出

```bash
# 修改 export.sh 中的 checkpoint 路径
bash export.sh
```

---




