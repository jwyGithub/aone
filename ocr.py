#!/usr/bin/env python3
"""最小图形验证码识别：python3 ocr.py <图片路径> -> stdout 输出验证码文本"""
import sys

from ddddocr import DdddOcr

try:
    ocr = DdddOcr(show_ad=False)
except TypeError:
    # 兼容不同版本签名
    ocr = DdddOcr()

with open(sys.argv[1], "rb") as f:
    data = f.read()

print(ocr.classification(data))
