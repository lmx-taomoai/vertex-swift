CUDA_VISIBLE_DEVICES=0 \
swift export \
    --adapters /root/autodl-tmp/qwen3_swift/output/v2-20251029-141114/checkpoint-424 \
    --merge_lora true
