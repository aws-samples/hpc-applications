#!/bin/bash
# This script downloads the AD domain certificate from Secrets Manager
# and places it where SSSD expects it for LDAPS verification.
# It runs as OnNodeStart (before SSSD is configured).

CERT_PATH="/opt/parallelcluster/shared/directory_service/domain-certificate.crt"
SECRET_ARN="$1"
REGION=$(ec2-metadata -z | awk '{print substr($2, 1, length($2)-1)}')

mkdir -p "$(dirname "$CERT_PATH")"
aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString \
  --output text \
  --region "$REGION" > "$CERT_PATH"
chmod 644 "$CERT_PATH"
