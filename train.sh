#!/bin/bash

# Swift 微调训练启动脚本 - Vertex AI 版本
# 用于在 Vertex AI Custom Job 中训练 Qwen3-VL 模型

set -e

echo "=========================================="
echo "Swift 训练启动 - Vertex AI"
echo "=========================================="

# 配置参数（可通过环境变量覆盖）
# 模型已打包在镜像中
MODEL_PATH="${MODEL_PATH:-/app/models/models--Qwen--Qwen3-VL-4B-Instruct}"
GCS_OUTPUT_PATH="${GCS_OUTPUT_PATH:-gs://im-drawing-462011-outputs}"
OUTPUT_DIR="${OUTPUT_DIR:-/app/output}"
TRAIN_DATASET="${TRAIN_DATASET:-view.jsonl}"
TRAIN_DATASET_EX="${TRAIN_DATASET_EX:-view_ex.jsonl}"

# 训练超参数
NUM_EPOCHS="${NUM_EPOCHS:-2}"
BATCH_SIZE="${BATCH_SIZE:-1}"
LEARNING_RATE="${LEARNING_RATE:-1e-4}"
LORA_RANK="${LORA_RANK:-8}"
LORA_ALPHA="${LORA_ALPHA:-32}"
MAX_LENGTH="${MAX_LENGTH:-3000}"
NPROC_PER_NODE="${NPROC_PER_NODE:-1}"

echo "训练配置:"
echo "  模型路径: $MODEL_PATH"
echo "  输出目录: $OUTPUT_DIR"
echo "  训练数据集: $TRAIN_DATASET, $TRAIN_DATASET_EX"
echo "  训练轮数: $NUM_EPOCHS"
echo "  批次大小: $BATCH_SIZE"
echo "  学习率: $LEARNING_RATE"
echo "  LoRA Rank: $LORA_RANK"
echo "=========================================="

# 检查 Google Cloud 认证
echo "检查 Google Cloud 认证..."
if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    echo "✓ 已通过 Service Account 认证"
else
    echo "警告: 未检测到活动认证，使用元数据服务器自动认证..."
fi

# 模型已打包在镜像中，直接验证
echo "=========================================="
echo "使用镜像内置模型: $MODEL_PATH"
echo "=========================================="

if [ ! -d "$MODEL_PATH" ]; then
    echo "✗ 模型路径不存在: $MODEL_PATH"
    echo "请确保模型已打包在镜像中！"
    exit 1
fi

# 修复 HuggingFace cache 路径结构
# HF cache 格式：models--Qwen--Qwen3-VL-4B-Instruct/snapshots/xxxxx/
if [ -d "$MODEL_PATH/snapshots" ]; then
    echo "检测到 HuggingFace cache 格式，查找实际模型目录..."
    SNAPSHOT_DIR=$(find "$MODEL_PATH/snapshots" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -n "$SNAPSHOT_DIR" ] && [ -f "$SNAPSHOT_DIR/config.json" ]; then
        echo "✓ 找到模型快照: $SNAPSHOT_DIR"
        MODEL_PATH="$SNAPSHOT_DIR"
    else
        echo "✗ 无法找到有效的模型快照"
        exit 1
    fi
fi

echo "✓ 模型路径验证成功: $MODEL_PATH"
echo "检查关键文件:"
if [ -f "$MODEL_PATH/config.json" ]; then
    echo "  ✓ config.json"
    # 显示 model_type
    MODEL_TYPE_IN_CONFIG=$(python -c "import json; print(json.load(open('$MODEL_PATH/config.json')).get('model_type', 'NOT_FOUND'))" 2>/dev/null || echo "unknown")
    echo "  ✓ model_type in config: $MODEL_TYPE_IN_CONFIG"
else
    echo "  ✗ config.json 未找到"
    exit 1
fi

ls -lh "$MODEL_PATH" | head -10

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 检查数据集文件是否存在
if [ ! -f "$TRAIN_DATASET" ]; then
    echo "错误: 训练数据集不存在: $TRAIN_DATASET"
    exit 1
fi

if [ ! -f "$TRAIN_DATASET_EX" ]; then
    echo "警告: 扩展数据集不存在: $TRAIN_DATASET_EX，将只使用主数据集"
    TRAIN_DATASET_EX=""
fi

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 检查 GPU 可用性
echo "检查 GPU 状态..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi
    GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
    echo "检测到 $GPU_COUNT 个 GPU"
else
    echo "警告: 未检测到 GPU，将使用 CPU 训练（非常慢）"
    GPU_COUNT=0
fi

# 设置 CUDA 可见设备
if [ "$GPU_COUNT" -gt 0 ]; then
    # 如果有多个 GPU，根据 NPROC_PER_NODE 设置
    if [ "$GPU_COUNT" -ge "$NPROC_PER_NODE" ]; then
        GPU_IDS=$(seq -s',' 0 $((NPROC_PER_NODE-1)))
        export CUDA_VISIBLE_DEVICES="$GPU_IDS"
        echo "使用 GPU: $CUDA_VISIBLE_DEVICES"
    else
        export CUDA_VISIBLE_DEVICES=$(seq -s',' 0 $((GPU_COUNT-1)))
        NPROC_PER_NODE=$GPU_COUNT
        echo "GPU 数量不足，调整为: $NPROC_PER_NODE"
    fi
else
    export CUDA_VISIBLE_DEVICES=""
fi

# 设置环境变量
export QWENVL_BBOX_FORMAT='new'
# 移除 expandable_segments（在某些平台不支持）
# export PYTORCH_CUDA_ALLOC_CONF='expandable_segments:True'
export IMAGE_MAX_TOKEN_NUM=1280
export VIDEO_MAX_TOKEN_NUM=128
export FPS_MAX_FRAMES=16

# 如果设置了 HF_TOKEN，配置 Hugging Face 认证（用于下载受限模型）
if [ -n "$HF_TOKEN" ]; then
    echo "✓ 检测到 HF_TOKEN，将用于 Hugging Face 认证"
    export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
fi

# 检查 Swift 安装
echo "检查 Swift 安装..."
if ! command -v swift &> /dev/null; then
    echo "错误: Swift 未安装"
    exit 1
fi

# 检查 Swift 版本和支持的模型
echo "检查 Swift 版本和支持的模型..."
python -c "import swift; print('✓ Swift 版本:', swift.__version__)" || echo "⚠️  无法获取 Swift 版本"

# 检查 Qwen3-VL 模型支持
echo "检查 Qwen3-VL 模型支持..."
# 根据官方文档，Qwen3-VL-4B-Instruct 的模型类型是 qwen3_vl
QWEN_MODEL_TYPE=$(python -c "
from swift.llm import MODEL_MAPPING
qwen_models = [k for k in MODEL_MAPPING.keys() if 'qwen' in k.lower()]
if qwen_models:
    # 优先选择 qwen3_vl（Qwen3-VL-4B-Instruct 官方类型）
    for preferred in ['qwen3_vl', 'qwen3-vl', 'qwen2_5-vl', 'qwen2-vl', 'qwen-vl']:
        if preferred in qwen_models:
            print(preferred)
            exit(0)
    print(qwen_models[0])  # 使用第一个匹配的
else:
    print('qwen3_vl')  # 默认值（根据官方文档）
" 2>/dev/null || echo "qwen3_vl")

echo "✓ 将使用模型类型: $QWEN_MODEL_TYPE"

# 构建数据集参数
DATASET_ARGS="--dataset '$TRAIN_DATASET'"
if [ -n "$TRAIN_DATASET_EX" ]; then
    DATASET_ARGS="$DATASET_ARGS '$TRAIN_DATASET_EX'"
fi

# 根据 GPU 数量决定是否使用 DeepSpeed
USE_DEEPSPEED=false
if [ "$NPROC_PER_NODE" -gt 1 ]; then
    USE_DEEPSPEED=true
    echo "使用 DeepSpeed Zero3 进行多GPU训练"
fi

# 启动训练
echo ""
echo "=========================================="
echo "开始训练..."
echo "=========================================="

# 构建训练命令
# 使用动态检测的模型类型
echo "使用模型路径: $MODEL_PATH"
echo "使用模型类型: $QWEN_MODEL_TYPE"
TRAIN_CMD="NPROC_PER_NODE=$NPROC_PER_NODE swift sft \
    --model $MODEL_PATH \
    --model_type $QWEN_MODEL_TYPE \
    --dataset '$TRAIN_DATASET'"

# 添加扩展数据集（如果存在）
if [ -n "$TRAIN_DATASET_EX" ]; then
    TRAIN_CMD="$TRAIN_CMD '$TRAIN_DATASET_EX'"
fi

# 添加其他参数
TRAIN_CMD="$TRAIN_CMD \
    --strict true \
    --load_from_cache_file true \
    --split_dataset_ratio 0.01 \
    --train_type lora \
    --torch_dtype bfloat16 \
    --num_train_epochs $NUM_EPOCHS \
    --per_device_train_batch_size $BATCH_SIZE \
    --per_device_eval_batch_size $BATCH_SIZE \
    --attn_impl flash_attn \
    --padding_free true \
    --learning_rate $LEARNING_RATE \
    --lora_rank $LORA_RANK \
    --lora_alpha $LORA_ALPHA \
    --target_modules all-linear \
    --freeze_vit false \
    --freeze_aligner false \
    --packing true \
    --gradient_checkpointing true \
    --vit_gradient_checkpointing false \
    --gradient_accumulation_steps 2 \
    --eval_steps 100 \
    --save_steps 100 \
    --save_total_limit 2 \
    --logging_steps 5 \
    --max_length $MAX_LENGTH \
    --output_dir $OUTPUT_DIR \
    --warmup_ratio 0.05 \
    --dataset_num_proc 4 \
    --dataloader_num_workers 4"

# 如果使用多GPU，添加 DeepSpeed
if [ "$USE_DEEPSPEED" = true ]; then
    TRAIN_CMD="$TRAIN_CMD --deepspeed zero3"
fi

# 执行训练
eval $TRAIN_CMD

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✓ 训练完成!"
    echo "输出目录: $OUTPUT_DIR"
    echo "=========================================="
    
    # 列出输出文件
    echo "输出文件列表:"
    ls -lh "$OUTPUT_DIR"
    
    # 如果配置了 GCS 输出路径，上传结果
    if [ -n "$GCS_OUTPUT_PATH" ]; then
        echo ""
        echo "=========================================="
        echo "上传训练结果到 GCS: $GCS_OUTPUT_PATH"
        echo "=========================================="
        
        gsutil -m cp -r "$OUTPUT_DIR"/* "$GCS_OUTPUT_PATH"/
        
        if [ $? -eq 0 ]; then
            echo "✓ 上传成功"
        else
            echo "✗ 上传失败"
            echo "请检查 Service Account 是否有写入权限"
            exit 1
        fi
    else
        echo "⚠️  未配置 GCS_OUTPUT_PATH，输出未上传"
    fi
else
    echo ""
    echo "=========================================="
    echo "✗ 训练失败，退出码: $EXIT_CODE"
    echo "=========================================="
    exit $EXIT_CODE
fi
