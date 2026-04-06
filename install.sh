#!/usr/bin/env bash
set -euo pipefail

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/cleardusk/doubao-im-auto-send.git}"

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH:-.}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"
TARGET_PATH="${TARGET_DIR}/doubao-im-auto-send"

command -v swiftc >/dev/null 2>&1 || {
  echo "错误: 未找到 swiftc，请先安装 Xcode Command Line Tools 或 Swift。" >&2
  exit 1
}

trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf "${TMP_DIR}"' EXIT

SOURCE_DIR="${SCRIPT_DIR}"
if ! compgen -G "${SOURCE_DIR}"/*.swift >/dev/null; then
  command -v git >/dev/null 2>&1 || {
    echo "错误: 当前目录没有 Swift 源码，且未找到 git 用于拉取仓库。" >&2
    exit 1
  }
  TMP_DIR="$(mktemp -d)"
  git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${TMP_DIR}/repo" >/dev/null 2>&1
  SOURCE_DIR="${TMP_DIR}/repo"
fi

compgen -G "${SOURCE_DIR}"/*.swift >/dev/null || {
  echo "错误: 未找到可编译的 Swift 源码文件。" >&2
  exit 1
}

mkdir -p "${TARGET_DIR}"
swiftc "${SOURCE_DIR}"/*.swift -o "${TARGET_PATH}"
chmod +x "${TARGET_PATH}"

echo "已安装到: ${TARGET_PATH}"

if [[ ":${PATH}:" != *":${TARGET_DIR}:"* ]]; then
  echo "提示: ${TARGET_DIR} 当前不在 PATH 中。"
  echo "可直接运行: ${TARGET_PATH} --help"
fi
