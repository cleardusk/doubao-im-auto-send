#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="cleardusk"
REPO_NAME="doubao-im-auto-send"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/${REPO_OWNER}/${REPO_NAME}.git}"
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}}"
SOURCE_FILE="doubao-im-auto-send.swift"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"
TARGET_PATH="${TARGET_DIR}/doubao-im-auto-send"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误: 未找到 swiftc，请先安装 Xcode Command Line Tools 或 Swift。" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

trap cleanup EXIT

resolve_source_path() {
  local local_source="${SCRIPT_DIR}/${SOURCE_FILE}"
  if [[ -f "${local_source}" ]]; then
    printf '%s\n' "${local_source}"
    return 0
  fi

  TMP_DIR="$(mktemp -d)"
  local downloaded_source="${TMP_DIR}/${SOURCE_FILE}"
  local download_url="${RAW_BASE_URL}/${SOURCE_FILE}"

  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "${download_url}" -o "${downloaded_source}"; then
      printf '%s\n' "${downloaded_source}"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO "${downloaded_source}" "${download_url}"; then
      printf '%s\n' "${downloaded_source}"
      return 0
    fi
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "错误: 未找到 git，且无法从 ${download_url} 下载 ${SOURCE_FILE}。" >&2
    exit 1
  fi

  local repo_checkout="${TMP_DIR}/repo"
  git clone --depth 1 "${REPO_URL}" "${repo_checkout}" >/dev/null 2>&1

  local fallback_source="${repo_checkout}/${SOURCE_FILE}"
  if [[ ! -f "${fallback_source}" ]]; then
    echo "错误: 下载失败，且在临时仓库中未找到 ${SOURCE_FILE}。" >&2
    exit 1
  fi

  printf '%s\n' "${fallback_source}"
}

SOURCE_PATH="$(resolve_source_path)"

mkdir -p "${TARGET_DIR}"
swiftc "${SOURCE_PATH}" -o "${TARGET_PATH}"
chmod +x "${TARGET_PATH}"

echo "已安装到: ${TARGET_PATH}"

if [[ ":${PATH}:" != *":${TARGET_DIR}:"* ]]; then
  echo "提示: ${TARGET_DIR} 当前不在 PATH 中。"
  echo "可直接运行: ${TARGET_PATH} --help"
fi
