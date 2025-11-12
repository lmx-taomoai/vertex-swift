# Swift 微调训练 Dockerfile for Vertex AI
# 基于 PyTorch 2.5.1 + CUDA 12.4
FROM --platform=linux/amd64 pytorch/pytorch:2.5.1-cuda12.4-cudnn9-devel

WORKDIR /app

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    git \
    wget \
    curl \
    build-essential \
    libgl1-mesa-glx \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# 安装 Google Cloud SDK（包含 gsutil）
RUN curl -sSL https://sdk.cloud.google.com | bash
ENV PATH="/root/google-cloud-sdk/bin:${PATH}"

# 复制 requirements.txt 并安装 Python 依赖
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# 复制训练脚本和数据
COPY bard/ /app/bard/
COPY train.sh /app/train.sh

# 复制模型文件到镜像中
COPY models/models--Qwen--Qwen3-VL-4B-Instruct /app/models/models--Qwen--Qwen3-VL-4B-Instruct



RUN pip install flash-attn --no-build-isolation || echo "Flash attention 安装失败"

# 安装 ms-swift（最新版本）
RUN pip install 'ms-swift[llm]' -U

# 复制模型检查脚本
COPY check_swift_models.py /app/check_swift_models.py
RUN chmod +x /app/check_swift_models.py

# 验证 Swift 安装并显示支持的模型
RUN python /app/check_swift_models.py || echo "⚠️  Swift 模型检查失败，继续构建..."

# 给脚本添加可执行权限
RUN chmod +x /app/train.sh

# 设置工作目录
WORKDIR /app/bard

# 设置容器入口点
ENTRYPOINT ["/app/train.sh"]
