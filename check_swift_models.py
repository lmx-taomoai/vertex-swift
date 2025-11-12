#!/usr/bin/env python3
"""
检查 Swift 支持的模型类型
"""

try:
    from swift.llm import MODEL_MAPPING
    
    print("=" * 60)
    print("Swift 支持的模型类型:")
    print("=" * 60)
    
    # 查找 Qwen 相关的模型
    qwen_models = [k for k in MODEL_MAPPING.keys() if 'qwen' in k.lower()]
    
    if qwen_models:
        print("\nQwen 相关模型:")
        for model in sorted(qwen_models):
            print(f"  - {model}")
    else:
        print("\n⚠️  未找到 Qwen 相关模型")
    
    print(f"\n总共支持 {len(MODEL_MAPPING)} 个模型类型")
    print("\n前 20 个模型类型:")
    for i, model in enumerate(sorted(MODEL_MAPPING.keys())[:20], 1):
        print(f"  {i}. {model}")
    
    print("\n" + "=" * 60)
    
except ImportError as e:
    print(f"错误: 无法导入 Swift - {e}")
    print("请确保已安装 ms-swift: pip install 'ms-swift[llm]' -U")
except Exception as e:
    print(f"错误: {e}")

