#!/usr/bin/env bash
# Protects security findings while they pass between jobs as an artifact (artifacts of public repositories are public).
#
#   security-transfer.sh encrypt <dir>   uses SECURITY_TRANSFER_PUBLIC_KEY (repo variable); no secret needed
#   security-transfer.sh decrypt <dir>   uses SECURITY_TRANSFER_PRIVATE_KEY (secret)
#
# <dir>/security.json is encrypted with a random per-run AES-256 key, which is wrapped with the RSA public key
# (OAEP, SHA-256). Without a public key, plaintext is only allowed in private repositories (REPO_PRIVATE=true).
set -euo pipefail

mode="${1:?usage: security-transfer.sh encrypt|decrypt <dir>}"
dir="${2:?usage: security-transfer.sh encrypt|decrypt <dir>}"
OAEP=(-pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256)

case "$mode" in
  encrypt)
    count=$(jq length "$dir/security.json")
    if [[ -n "${SECURITY_TRANSFER_PUBLIC_KEY:-}" ]]; then
      pub=$(mktemp)
      printf '%s\n' "$SECURITY_TRANSFER_PUBLIC_KEY" > "$pub"
      KEY=$(openssl rand -hex 32)
      export KEY
      openssl enc -aes-256-cbc -pbkdf2 -salt -in "$dir/security.json" -out "$dir/security.json.enc" -pass env:KEY
      printf '%s' "$KEY" | openssl pkeyutl -encrypt -pubin -inkey "$pub" "${OAEP[@]}" -out "$dir/key.enc"
      unset KEY
      rm -f "$dir/security.json" "$pub"
      echo "Security findings: $count (encrypted)"
    elif [[ "$count" == 0 ]]; then
      echo "Security findings: 0"
    elif [[ "${REPO_PRIVATE:-}" == true ]]; then
      echo "Security findings: $count (plaintext; private repository without SECURITY_TRANSFER_PUBLIC_KEY)"
    else
      rm -f "$dir/security.json"
      echo "::error::$count security finding(s) cannot be transferred: set SECURITY_TRANSFER_PUBLIC_KEY in this public repository"
      exit 1
    fi
    ;;
  decrypt)
    if [[ ! -f "$dir/security.json.enc" ]]; then
      [[ -f "$dir/security.json" ]] || echo '[]' > "$dir/security.json"
      exit 0
    fi
    : "${SECURITY_TRANSFER_PRIVATE_KEY:?the SECURITY_TRANSFER_PRIVATE_KEY secret is required to decrypt security findings}"
    priv=$(mktemp)
    printf '%s\n' "$SECURITY_TRANSFER_PRIVATE_KEY" > "$priv"
    KEY=$(openssl pkeyutl -decrypt -inkey "$priv" -in "$dir/key.enc" "${OAEP[@]}")
    export KEY
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$dir/security.json.enc" -out "$dir/security.json" -pass env:KEY
    unset KEY
    rm -f "$priv" "$dir/security.json.enc" "$dir/key.enc"
    ;;
  *)
    echo "usage: security-transfer.sh encrypt|decrypt <dir>" >&2
    exit 2
    ;;
esac
