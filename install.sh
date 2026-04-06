#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"
TARGET_PATH="${TARGET_DIR}/doubao-im-auto-send"

mkdir -p "${TARGET_DIR}"
swiftc "${SCRIPT_DIR}/doubao-im-auto-send.swift" -o "${TARGET_PATH}"
chmod +x "${TARGET_PATH}"

echo "已安装到: ${TARGET_PATH}"

if [[ ":${PATH}:" != *":${TARGET_DIR}:"* ]]; then
  echo "提示: ${TARGET_DIR} 当前不在 PATH 中。"
  echo "可直接运行: ${TARGET_PATH} --help"
fi
