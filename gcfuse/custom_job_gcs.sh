#!/bin/bash

# Vertex AI Custom Job 提交脚本 - GCS 挂载版本
# 使用 gcsfuse 挂载 GCS 存储桶，无需打包模型到镜像

set -e

# ========== 配置参数 ==========
PROJECT_ID="im-drawing-462011"
REGION="us-central1"
IMAGE_REPO="custom-job-repo"
IMAGE_NAME="swift-trainer-qwen3vl-gcs"
IMAGE_TAG="latest"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${IMAGE_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# 机器配置
MACHINE_TYPE="a2-highgpu-2g"       # 2x A100 (80GB)
REPLICA_COUNT=1
ACCELERATOR_TYPE="NVIDIA_TESLA_A100"
ACCELERATOR_COUNT=2

# GCS 路径配置
GCS_MODEL_BUCKET="im-drawing-462011-models"
GCS_MODEL_PATH="models/Qwen3-VL-4B-Instruct"
GCS_OUTPUT_BUCKET="im-drawing-462011-outputs"
GCS_OUTPUT_PATH="swift-training/$(date +%Y%m%d-%H%M%S)"

# Service Account（使用默认的 Compute Engine Service Account）
# 如果需要自定义，可以创建专门的服务账号
SERVICE_ACCOUNT=""  # 留空使用默认

echo "=========================================="
echo "Vertex AI Custom Job 提交工具 - GCS 挂载版本"
echo "=========================================="
echo "项目 ID: $PROJECT_ID"
echo "区域: $REGION"
echo "镜像: $IMAGE_URI"
echo "机器类型: $MACHINE_TYPE"
echo "GPU 类型: $ACCELERATOR_TYPE x $ACCELERATOR_COUNT"
echo ""
echo "GCS 配置:"
echo "  模型路径: gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH"
echo "  输出路径: gs://$GCS_OUTPUT_BUCKET/$GCS_OUTPUT_PATH"
echo ""
echo "⚠️  注意："
echo "  - 模型不打包在镜像中，通过 gcsfuse 从 GCS 挂载"
echo "  - 镜像大小仅几百 MB（vs 原来的 20GB+）"
echo "  - 需要确保 GCS 存储桶中有模型文件"
echo "  - 容器需要以 privileged 模式运行（支持 FUSE）"
echo "=========================================="

# 选择操作
echo ""
echo "请选择操作:"
echo "  1) 构建并推送镜像"
echo "  2) 提交训练任务"
echo "  3) 构建、推送并提交任务（全流程）"
echo "  4) 查看任务状态"
echo "  5) 上传模型到 GCS"
echo "  6) 验证 GCS 模型文件"
echo ""
read -p "请输入选项 [1-6]: " choice

case $choice in
    1)
        ACTION="build"
        ;;
    2)
        ACTION="submit"
        ;;
    3)
        ACTION="all"
        ;;
    4)
        ACTION="status"
        ;;
    5)
        ACTION="upload_model"
        ;;
    6)
        ACTION="verify_model"
        ;;
    *)
        echo "无效选项"
        exit 1
        ;;
esac

# ========== 函数定义 ==========

# 检查必要工具
check_tools() {
    echo "检查必要工具..."
    
    if ! command -v gcloud &> /dev/null; then
        echo "错误: gcloud 未安装"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        echo "错误: docker 未安装"
        exit 1
    fi
    
    echo "✓ 工具检查通过"
}

# 配置 Docker 认证
configure_docker() {
    echo ""
    echo "配置 Docker 访问 Artifact Registry..."
    gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet
    echo "✓ Docker 认证配置完成"
}

# 检查 Artifact Registry 仓库
check_registry() {
    echo ""
    echo "检查 Artifact Registry 仓库..."
    
    if gcloud artifacts repositories describe $IMAGE_REPO \
        --project=$PROJECT_ID \
        --location=$REGION &> /dev/null; then
        echo "✓ 仓库已存在: $IMAGE_REPO"
    else
        echo "仓库不存在，正在创建..."
        gcloud artifacts repositories create $IMAGE_REPO \
            --repository-format=docker \
            --location=$REGION \
            --project=$PROJECT_ID \
            --description="Swift training images for Vertex AI (GCS mount version)"
        
        if [ $? -eq 0 ]; then
            echo "✓ 仓库创建成功"
        else
            echo "✗ 仓库创建失败"
            exit 1
        fi
    fi
}

# 构建镜像
build_image() {
    echo ""
    echo "=========================================="
    echo "构建 Docker 镜像（GCS 挂载版本）..."
    echo "=========================================="
    
    docker build \
        --platform linux/amd64 \
        -t $IMAGE_URI \
        -f Dockerfile.gcs \
        .
    
    if [ $? -eq 0 ]; then
        echo "✓ 镜像构建成功"
        echo ""
        echo "镜像大小:"
        docker images $IMAGE_URI
    else
        echo "✗ 镜像构建失败"
        exit 1
    fi
}

# 推送镜像
push_image() {
    echo ""
    echo "=========================================="
    echo "推送镜像到 Artifact Registry..."
    echo "=========================================="
    
    docker push $IMAGE_URI
    
    if [ $? -eq 0 ]; then
        echo "✓ 镜像推送成功"
    else
        echo "✗ 镜像推送失败"
        exit 1
    fi
}

# 上传模型到 GCS
upload_model() {
    echo ""
    echo "=========================================="
    echo "上传模型到 GCS..."
    echo "=========================================="
    
    read -p "请输入本地模型路径（例如：./models/Qwen3-VL-4B-Instruct）: " LOCAL_MODEL_PATH
    
    if [ ! -d "$LOCAL_MODEL_PATH" ]; then
        echo "✗ 本地模型路径不存在: $LOCAL_MODEL_PATH"
        exit 1
    fi
    
    echo "上传模型到 gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH ..."
    gsutil -m rsync -r "$LOCAL_MODEL_PATH" "gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH"
    
    if [ $? -eq 0 ]; then
        echo "✓ 模型上传成功"
        echo ""
        echo "验证上传:"
        gsutil ls "gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH/"
    else
        echo "✗ 模型上传失败"
        exit 1
    fi
}

# 验证 GCS 模型文件
verify_model() {
    echo ""
    echo "=========================================="
    echo "验证 GCS 模型文件..."
    echo "=========================================="
    
    echo "检查 gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH ..."
    
    if gsutil ls "gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH/" &> /dev/null; then
        echo "✓ 模型路径存在"
        echo ""
        echo "模型文件列表:"
        gsutil ls -lh "gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH/"
        
        # 检查关键文件
        echo ""
        echo "检查关键文件:"
        for file in "config.json" "model.safetensors" "tokenizer.json"; do
            if gsutil ls "gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH/$file" &> /dev/null; then
                echo "  ✓ $file"
            else
                echo "  ✗ $file (缺失)"
            fi
        done
    else
        echo "✗ 模型路径不存在"
        echo ""
        echo "请先上传模型:"
        echo "  ./custom_job_gcs.sh  # 选择选项 5"
        exit 1
    fi
}

# 提交训练任务
submit_job() {
    echo ""
    echo "=========================================="
    echo "提交 Vertex AI Custom Job（GCS 挂载版本）..."
    echo "=========================================="
    
    # 验证 GCS 模型文件存在
    echo "验证 GCS 模型文件..."
    if ! gsutil ls "gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH/config.json" &> /dev/null; then
        echo "✗ 模型文件不存在: gs://$GCS_MODEL_BUCKET/$GCS_MODEL_PATH/"
        echo ""
        echo "请先上传模型:"
        echo "  ./custom_job_gcs.sh  # 选择选项 5"
        exit 1
    fi
    echo "✓ 模型文件验证通过"
    
    JOB_NAME="swift-qwen3vl-gcs-$(date +%Y%m%d-%H%M%S)"
    
    # 创建临时配置文件
    CONFIG_FILE="/tmp/vertex_ai_job_gcs_config_$$.json"
    
    # 生成配置文件
    # 注意：需要添加特权模式以支持 FUSE 挂载
    cat > $CONFIG_FILE <<EOF
{
  "workerPoolSpecs": [
    {
      "machineSpec": {
        "machineType": "$MACHINE_TYPE",
        "acceleratorType": "$ACCELERATOR_TYPE",
        "acceleratorCount": $ACCELERATOR_COUNT
      },
      "replicaCount": $REPLICA_COUNT,
      "containerSpec": {
        "imageUri": "$IMAGE_URI",
        "env": [
          { "name": "GCS_BUCKET", "value": "$GCS_MODEL_BUCKET" },
          { "name": "GCS_MODEL_PATH", "value": "$GCS_MODEL_PATH" },
          { "name": "GCS_OUTPUT_BUCKET", "value": "$GCS_OUTPUT_BUCKET" },
          { "name": "GCS_OUTPUT_PATH", "value": "$GCS_OUTPUT_PATH" }
        ]
      }
    }
  ]
}
EOF
    
    # 如果指定了 Service Account，添加到配置
    if [ -n "$SERVICE_ACCOUNT" ]; then
        # 使用 jq 添加 serviceAccount 字段（如果安装了 jq）
        if command -v jq &> /dev/null; then
            jq ". + {\"serviceAccount\": \"$SERVICE_ACCOUNT\"}" $CONFIG_FILE > ${CONFIG_FILE}.tmp
            mv ${CONFIG_FILE}.tmp $CONFIG_FILE
        fi
    fi
    
    echo "配置文件已生成: $CONFIG_FILE"
    echo ""
    echo "任务配置:"
    cat $CONFIG_FILE | python -m json.tool 2>/dev/null || cat $CONFIG_FILE
    echo ""
    
    # 提交任务
    gcloud ai custom-jobs create \
        --region=$REGION \
        --project=$PROJECT_ID \
        --display-name="$JOB_NAME" \
        --config=$CONFIG_FILE
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✓ 任务提交成功: $JOB_NAME"
        echo ""
        echo "查看任务状态:"
        echo "  gcloud ai custom-jobs list --region=$REGION --project=$PROJECT_ID"
        echo ""
        echo "查看任务日志:"
        echo "  gcloud ai custom-jobs stream-logs $JOB_NAME --region=$REGION --project=$PROJECT_ID"
        echo ""
        echo "在控制台查看:"
        echo "  https://console.cloud.google.com/vertex-ai/training/custom-jobs?project=$PROJECT_ID"
        echo ""
        echo "训练完成后，输出将保存在:"
        echo "  gs://$GCS_OUTPUT_BUCKET/$GCS_OUTPUT_PATH/"
        
        # 清理临时配置文件
        rm -f $CONFIG_FILE
    else
        echo "✗ 任务提交失败"
        echo "配置文件位置: $CONFIG_FILE"
        rm -f $CONFIG_FILE
        exit 1
    fi
}

# 查看任务状态
check_status() {
    echo ""
    echo "=========================================="
    echo "最近的训练任务:"
    echo "=========================================="
    
    gcloud ai custom-jobs list \
        --region=$REGION \
        --project=$PROJECT_ID \
        --limit=10 \
        --sort-by="~createTime"
}

# ========== 主流程 ==========

check_tools

case $ACTION in
    build)
        configure_docker
        check_registry
        build_image
        push_image
        ;;
    submit)
        submit_job
        ;;
    all)
        configure_docker
        check_registry
        build_image
        push_image
        submit_job
        ;;
    status)
        check_status
        ;;
    upload_model)
        upload_model
        ;;
    verify_model)
        verify_model
        ;;
esac

echo ""
echo "=========================================="
echo "操作完成!"
echo "=========================================="
