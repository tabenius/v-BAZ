#!/bin/sh
set -eu
image_mib=$1; root_mib=$2; esp_mib=${3:-1024}; config_mib=${4:-512}
case "$image_mib:$root_mib:$esp_mib:$config_mib" in *[!0-9:]*|:*|*:) echo "sizes must be integer MiB values" >&2; exit 2;; esac
data_mib=$((image_mib - 1 - esp_mib - root_mib - root_mib - config_mib - 1))
[ "$data_mib" -ge 8192 ] || { echo "image too small: data partition would be ${data_mib} MiB" >&2; exit 2; }
cat <<EOF
IMAGE_MIB=$image_mib
ESP_START_MIB=1
ESP_SIZE_MIB=$esp_mib
ROOT_A_START_MIB=$((1 + esp_mib))
ROOT_A_SIZE_MIB=$root_mib
ROOT_B_START_MIB=$((1 + esp_mib + root_mib))
ROOT_B_SIZE_MIB=$root_mib
CONFIG_START_MIB=$((1 + esp_mib + root_mib + root_mib))
CONFIG_SIZE_MIB=$config_mib
DATA_START_MIB=$((1 + esp_mib + root_mib + root_mib + config_mib))
DATA_SIZE_MIB=$data_mib
EOF
