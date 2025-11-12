#!/bin/bash

# Vertex AI Custom Job 提交脚本
# 用于 Swift 框架训练 Qwen3-VL 模型

set -e

# ========== 配置参数 ==========
PROJECT_ID="im-drawing-462011"
REGION="us-central1"
IMAGE_REPO="custom-job-repo"
IMAGE_NAME="swift-trainer-qwen3vl"
IMAGE_TAG="latest"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${IMAGE_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# 机器配置
# MACHINE_TYPE="a2-highgpu-1g"         # 1x A100 (40GB)
MACHINE_TYPE="a2-highgpu-2g"       # 2x A100 (80GB)
REPLICA_COUNT=1
ACCELERATOR_TYPE="NVIDIA_TESLA_A100"
ACCELERATOR_COUNT=2

# 训练配置（通过环境变量传递给容器）
# 模型已打包在镜像中，只需配置输出路径
GCS_OUTPUT_PATH="gs://${PROJECT_ID}-outputs/swift-training/$(date +%Y%m%d-%H%M%S)"

# 注意：
# - 模型已打包在镜像中（/app/models/models--Qwen--Qwen3-VL-4B-Instruct）
# - 镜像大小约 20GB+，首次构建和推送较慢（30-60分钟）
# - 训练启动快（无需下载模型）
# - 训练完成后自动上传输出到 GCS

# Service Account（使用默认的 GCS Service Account）
SERVICE_ACCOUNT="service-1003882345878@gs-project-accounts.iam.gserviceaccount.com"

echo "=========================================="
echo "Vertex AI Custom Job 提交工具"
echo "=========================================="
echo "项目 ID: $PROJECT_ID"
echo "区域: $REGION"
echo "镜像: $IMAGE_URI"
echo "机器类型: $MACHINE_TYPE"
echo "GPU 类型: $ACCELERATOR_TYPE x $ACCELERATOR_COUNT"
echo "模型: 已打包在镜像中"
echo "输出路径: $GCS_OUTPUT_PATH"
echo "Service Account: $SERVICE_ACCOUNT"
echo "=========================================="

# 选择操作
echo ""
echo "请选择操作:"
echo "  1) 构建并推送镜像"
echo "  2) 提交训练任务"
echo "  3) 构建、推送并提交任务（全流程）"
echo "  4) 查看任务状态"
echo ""
read -p "请输入选项 [1-4]: " choice

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
            --description="Swift training images for Vertex AI"
        
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
    echo "构建 Docker 镜像..."
    echo "=========================================="
    
    docker build \
        --platform linux/amd64 \
        -t $IMAGE_URI \
        -f Dockerfile \
        .
    
    if [ $? -eq 0 ]; then
        echo "✓ 镜像构建成功"
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

# 提交训练任务
submit_job() {
    echo ""
    echo "=========================================="
    echo "提交 Vertex AI Custom Job..."
    echo "=========================================="
    
    JOB_NAME="swift-qwen3vl-training-$(date +%Y%m%d-%H%M%S)"
    
    # 创建临时配置文件
    CONFIG_FILE="/tmp/vertex_ai_job_config_$$.json"
    
    # 检查 Service Account 是否存在
    if gcloud iam service-accounts describe $SERVICE_ACCOUNT --project=$PROJECT_ID &>/dev/null; then
        echo "✓ Service Account 存在: $SERVICE_ACCOUNT"
        USE_SERVICE_ACCOUNT=true
    else
        echo "⚠️  Service Account 不存在: $SERVICE_ACCOUNT"
        echo "   将使用默认服务账号（可能权限不足）"
        echo "   建议运行: ./setup_service_account.sh"
        USE_SERVICE_ACCOUNT=false
    fi
    
    # 生成配置文件（只包含 job spec 内容）
    if [ "$USE_SERVICE_ACCOUNT" = true ]; then
        # 使用自定义 Service Account
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
          { "name": "GCS_OUTPUT_PATH", "value": "$GCS_OUTPUT_PATH" }
        ]
      }
    }
  ],
  "serviceAccount": "$SERVICE_ACCOUNT"
}
EOF
    else
        # 使用默认 Service Account
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
          { "name": "GCS_OUTPUT_PATH", "value": "$GCS_OUTPUT_PATH" }
        ]
      }
    }
  ]
}
EOF
    fi
    
    echo "配置文件已生成: $CONFIG_FILE"
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
esac

echo ""
echo "=========================================="
echo "操作完成!"
echo "=========================================="
