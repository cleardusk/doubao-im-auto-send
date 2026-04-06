#!/usr/bin/env bash
set -euo pipefail

SOURCE_FILE="doubao-im-auto-send.swift"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/cleardusk/doubao-im-auto-send/${REPO_BRANCH}/${SOURCE_FILE}}"
REPO_URL="${REPO_URL:-https://github.com/cleardusk/doubao-im-auto-send.git}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"
TARGET_PATH="${TARGET_DIR}/doubao-im-auto-send"

command -v swiftc >/dev/null 2>&1 || {
  echo "错误: 未找到 swiftc，请先安装 Xcode Command Line Tools 或 Swift。" >&2
  exit 1
}

trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf "${TMP_DIR}"' EXIT

SOURCE_PATH="${SCRIPT_DIR}/${SOURCE_FILE}"
if [[ ! -f "${SOURCE_PATH}" ]]; then
  TMP_DIR="$(mktemp -d)"
  SOURCE_PATH="${TMP_DIR}/${SOURCE_FILE}"

  if ! curl -fsSL "${RAW_URL}" -o "${SOURCE_PATH}" \
    && ! { command -v wget >/dev/null 2>&1 && wget -qO "${SOURCE_PATH}" "${RAW_URL}"; }; then
    command -v git >/dev/null 2>&1 || {
      echo "错误: 无法下载 ${SOURCE_FILE}，且未找到 git。" >&2
      exit 1
    }
    git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${TMP_DIR}/repo" >/dev/null 2>&1
    SOURCE_PATH="${TMP_DIR}/repo/${SOURCE_FILE}"
    [[ -f "${SOURCE_PATH}" ]] || {
      echo "错误: 下载失败，且仓库中未找到 ${SOURCE_FILE}。" >&2
      exit 1
    }
  fi
fi

mkdir -p "${TARGET_DIR}"
swiftc "${SOURCE_PATH}" -o "${TARGET_PATH}"
chmod +x "${TARGET_PATH}"

echo "已安装到: ${TARGET_PATH}"

if [[ ":${PATH}:" != *":${TARGET_DIR}:"* ]]; then
  echo "提示: ${TARGET_DIR} 当前不在 PATH 中。"
  echo "可直接运行: ${TARGET_PATH} --help"
fi
