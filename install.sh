#!/bin/bash
# 检测设备架构
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    curl -o flash_tool https://你的链接/flash_tool_arm64 && chmod +x flash_tool && ./flash_tool
elif [ "$ARCH" = "x86_64" ]; then
    curl -o flash_tool https://你的链接/flash_tool_x86 && chmod +x flash_tool && ./flash_tool
else
    echo "不支持的设备架构：$ARCH"
fi

