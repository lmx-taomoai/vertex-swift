# GCS 挂载版本使用指南

## 概述

这是使用 **gcsfuse** 挂载 GCS 存储桶的训练版本，相比原版本有以下优势：

### ✅ 优势

1. **镜像大小大幅减小**
   - 原版本：20GB+（包含模型文件）
   - GCS 版本：几百 MB（不包含模型）
   - 构建和推送速度快 10-20 倍

2. **灵活性更高**
   - 可以随时更换模型，无需重新构建镜像
   - 多个训练任务可以共享同一个模型
   - 输出直接写入 GCS，无需手动上传

3. **成本更低**
   - 镜像存储成本降低 95%+
   - 网络传输成本降低（镜像更小）

### ⚠️ 注意事项

1. **需要在 GCS 中预先存储模型**
2. **首次挂载可能有延迟**（几秒到几十秒）
3. **需要容器有 FUSE 权限**

## 文件结构

```
gcl_swift_sft/
├── train_gcs.sh           # GCS 挂载版本的训练脚本
├── Dockerfile.gcs         # GCS 挂载版本的 Dockerfile
├── custom_job_gcs.sh      # GCS 挂载版本的提交脚本
├── bard/                  # 数据集目录（本地）
│   ├── view.jsonl
│   └── view_ex.jsonl
└── (原版文件保持不变)
```

## 快速开始

### 步骤 1：上传模型到 GCS

如果模型还没有上传到 GCS：

```bash
cd /Users/lmx/code/gcl_swift_sft

# 方式 1：使用脚本上传
./custom_job_gcs.sh
# 选择选项 5，然后输入本地模型路径

# 方式 2：手动上传
gsutil -m rsync -r ./models/Qwen3-VL-4B-Instruct gs://im-drawing-462011-models/models/Qwen3-VL-4B-Instruct
```

### 步骤 2：验证模型文件

```bash
./custom_job_gcs.sh
# 选择选项 6

# 或者手动验证
gsutil ls gs://im-drawing-462011-models/models/Qwen3-VL-4B-Instruct/
```

应该看到以下文件：
- `config.json` ✅
- `model.safetensors` ✅
- `tokenizer.json` ✅
- 等其他模型文件

### 步骤 3：构建并推送镜像

```bash
./custom_job_gcs.sh
# 选择选项 1（构建并推送镜像）

# 或者全流程
# 选择选项 3（构建、推送并提交任务）
```

### 步骤 4：提交训练任务

```bash
./custom_job_gcs.sh
# 选择选项 2（提交训练任务）
```

### 步骤 5：查看任务状态

```bash
./custom_job_gcs.sh
# 选择选项 4

# 或者查看日志
gcloud ai custom-jobs stream-logs <JOB_NAME> --region=us-central1 --project=im-drawing-462011
```

### 步骤 6：获取训练结果

训练完成后，输出会自动保存到 GCS：

```bash
# 列出输出文件
gsutil ls gs://im-drawing-462011-outputs/swift-training/

# 下载输出
gsutil -m cp -r gs://im-drawing-462011-outputs/swift-training/YYYYMMDD-HHMMSS/ ./output/
```

## 工作原理

### 1. 镜像构建

```dockerfile
# Dockerfile.gcs
# 1. 安装 gcsfuse
RUN apt-get install -y gcsfuse

# 2. 不包含模型文件
# （镜像大小从 20GB+ 降到几百 MB）

# 3. 创建挂载目录
RUN mkdir -p /mnt/gcs/models /mnt/gcs/output
```

### 2. 容器启动时

```bash
# train_gcs.sh

# 1. 挂载模型存储桶（只读）
gcsfuse --only-dir "$GCS_MODEL_PATH" "$GCS_BUCKET" /mnt/gcs/models

# 2. 挂载输出存储桶（读写）
gcsfuse "$GCS_OUTPUT_BUCKET" /mnt/gcs/output

# 3. 使用挂载的路径进行训练
swift sft \
    --model /mnt/gcs/models \       # GCS 挂载的模型
    --output_dir /mnt/gcs/output    # GCS 挂载的输出
```

### 3. 训练过程中

```
训练进程
    ↓
读取模型：/mnt/gcs/models
    ↓ (gcsfuse)
gs://im-drawing-462011-models/models/Qwen3-VL-4B-Instruct
    ↓
写入输出：/mnt/gcs/output
    ↓ (gcsfuse)
gs://im-drawing-462011-outputs/swift-training/...
```

### 4. 清理

```bash
# 训练结束后自动卸载
fusermount -u /mnt/gcs/models
fusermount -u /mnt/gcs/output
```

## 配置说明

### 环境变量

在 `custom_job_gcs.sh` 中可以配置：

```bash
# GCS 路径配置
GCS_MODEL_BUCKET="im-drawing-462011-models"        # 模型存储桶
GCS_MODEL_PATH="models/Qwen3-VL-4B-Instruct"       # 模型路径
GCS_OUTPUT_BUCKET="im-drawing-462011-outputs"      # 输出存储桶
GCS_OUTPUT_PATH="swift-training/$(date +%Y%m%d-%H%M%S)"  # 输出路径

# 机器配置
MACHINE_TYPE="a2-highgpu-2g"       # 2x A100 (80GB)
ACCELERATOR_TYPE="NVIDIA_TESLA_A100"
ACCELERATOR_COUNT=2
```

### gcsfuse 挂载参数

在 `train_gcs.sh` 中：

```bash
# 模型挂载（只读，优化缓存）
gcsfuse \
    --implicit-dirs \
    --stat-cache-ttl 60s \      # 文件状态缓存 60 秒
    --type-cache-ttl 60s \      # 类型缓存 60 秒
    --dir-mode 0755 \
    --file-mode 0644 \
    --only-dir "$GCS_MODEL_PATH" \  # 只挂载指定目录
    "$GCS_BUCKET" "$MODEL_MOUNT"

# 输出挂载（读写，较短缓存）
gcsfuse \
    --implicit-dirs \
    --stat-cache-ttl 10s \      # 更短的缓存时间
    --type-cache-ttl 10s \
    --dir-mode 0755 \
    --file-mode 0644 \
    "$GCS_OUTPUT_BUCKET" "$OUTPUT_MOUNT"
```

## 性能优化

### 1. 缓存策略

- **模型挂载**：较长的缓存时间（60s），因为模型文件不会改变
- **输出挂载**：较短的缓存时间（10s），确保及时同步

### 2. 只挂载需要的目录

```bash
# 只挂载模型目录，不挂载整个存储桶
--only-dir "$GCS_MODEL_PATH"
```

### 3. 预热（可选）

如果需要更快的启动速度，可以在训练前预加载模型：

```bash
# 在 train_gcs.sh 中添加
echo "预加载模型文件..."
find "$MODEL_MOUNT" -type f -name "*.safetensors" -exec cat {} > /dev/null \;
```

## 对比：原版 vs GCS 挂载版

| 特性 | 原版 | GCS 挂载版 |
|-----|-----|-----------|
| **镜像大小** | 20GB+ | 几百 MB |
| **构建时间** | 30-60 分钟 | 5-10 分钟 |
| **推送时间** | 20-40 分钟 | 2-5 分钟 |
| **启动时间** | 快（模型已在镜像中） | 稍慢（需要挂载，首次 10-30 秒） |
| **灵活性** | 低（换模型需重建镜像） | 高（随时更换模型） |
| **存储成本** | 高（每个镜像 20GB+） | 低（镜像几百 MB，模型共享） |
| **适用场景** | 固定模型，快速启动 | 灵活实验，多模型切换 |

## 故障排查

### 问题 1：挂载失败

```bash
# 错误
fusermount: failed to open /dev/fuse: Operation not permitted
```

**原因**：容器没有 FUSE 权限

**解决**：Vertex AI 默认支持 gcsfuse，通常不会出现此问题。如果出现，联系 GCP 支持。

### 问题 2：模型文件找不到

```bash
# 错误
✗ 模型路径不存在: /mnt/gcs/models
```

**解决**：
1. 验证 GCS 路径是否正确
2. 检查 Service Account 是否有读取权限
3. 运行验证命令：
   ```bash
   ./custom_job_gcs.sh  # 选择选项 6
   ```

### 问题 3：输出无法写入

```bash
# 错误
Permission denied: /mnt/gcs/output/...
```

**解决**：
1. 检查 Service Account 是否有写入权限
2. 确认存储桶存在：
   ```bash
   gsutil ls gs://im-drawing-462011-outputs/
   ```

### 问题 4：性能较慢

**优化建议**：
1. 增加缓存时间（如果模型文件大）
2. 使用区域存储桶（与 Vertex AI 相同区域）
3. 考虑预加载关键文件

## 最佳实践

### 1. 模型管理

```bash
# 组织模型结构
gs://bucket/
├── models/
│   ├── Qwen3-VL-4B-Instruct/
│   ├── Qwen3-VL-7B-Instruct/
│   └── other-model/
└── outputs/
    └── swift-training/
        ├── 20251030-143022/
        └── 20251030-150145/
```

### 2. 版本控制

```bash
# 使用日期标记输出
GCS_OUTPUT_PATH="swift-training/$(date +%Y%m%d-%H%M%S)"

# 或使用实验名称
GCS_OUTPUT_PATH="swift-training/exp-lora-rank8"
```

### 3. 清理旧输出

```bash
# 列出所有输出
gsutil ls gs://im-drawing-462011-outputs/swift-training/

# 删除旧的输出（谨慎操作）
gsutil -m rm -r gs://im-drawing-462011-outputs/swift-training/OLD_DIR/
```

## 总结

GCS 挂载版本适合：
- ✅ 需要频繁切换模型
- ✅ 多个实验共享模型
- ✅ 希望减小镜像大小
- ✅ 希望加快构建速度

原版本适合：
- ✅ 固定模型，不常更换
- ✅ 需要最快的启动速度
- ✅ 离线或受限网络环境

**推荐**：大多数情况下使用 **GCS 挂载版本**，它更灵活、成本更低！
