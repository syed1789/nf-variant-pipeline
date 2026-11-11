#!/usr/bin/env bash
# Launch a one-shot EC2 instance that runs this analysis and uploads the
# results to S3, then terminates itself. Requires the AWS CLI and credentials.
#
#   export S3_BUCKET=my-bucket          # existing bucket you can write to
#   export INSTANCE_PROFILE=my-ec2-role # IAM instance profile with s3:PutObject
#   ./aws/launch_ec2.sh
#
# Optional: INSTANCE_TYPE (m6i.2xlarge), VOLUME_GB (100), AWS_REGION (us-east-1),
# GIT_REF (main), SUBNET_ID, SECURITY_GROUP_IDS, MAX_HOURS (12),
# INPUT_S3 (s3://... synced into the repo before running, for supplied data).
set -euo pipefail

: "${S3_BUCKET:?set S3_BUCKET}"
: "${INSTANCE_PROFILE:?set INSTANCE_PROFILE (IAM instance profile name)}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m6i.2xlarge}"
VOLUME_GB="${VOLUME_GB:-100}"
REGION="${AWS_REGION:-us-east-1}"
GIT_REF="${GIT_REF:-main}"
MAX_HOURS="${MAX_HOURS:-12}"
INPUT_S3="${INPUT_S3:-}"
REPO_URL="https://github.com/syed1789/nf-variant-pipeline.git"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
S3_PREFIX="s3://${S3_BUCKET}/nf-variant-pipeline/${RUN_ID}"

AMI="$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)"

USER_DATA="$(mktemp)"
cat > "$USER_DATA" <<EOF
#!/bin/bash
set -x
exec > >(tee /var/log/analysis.log) 2>&1
# Dead-man switch: stop paying even if something hangs.
shutdown -h +$((MAX_HOURS * 60))
finish() {
  aws s3 cp /var/log/analysis.log "$S3_PREFIX/analysis.log" || true
  shutdown -h now
}
trap finish EXIT

dnf install -y docker git java-17-amazon-corretto-headless
systemctl enable --now docker
mkdir -p /opt/nf && cd /opt/nf && curl -s https://get.nextflow.io | bash && mv nextflow /usr/local/bin/ && cd /
git clone --depth 1 --branch "$GIT_REF" "$REPO_URL" /work/repo
cd /work/repo
if [ -n "$INPUT_S3" ]; then aws s3 sync "$INPUT_S3" ./test_data/; fi
nextflow run main.nf -profile docker
for d in results; do
  if [ -e "\$d" ]; then aws s3 sync "\$d" "$S3_PREFIX/\$d" || aws s3 cp "\$d" "$S3_PREFIX/\$d"; fi
done
EOF

NETARGS=()
[ -n "${SUBNET_ID:-}" ] && NETARGS+=(--subnet-id "$SUBNET_ID")
# shellcheck disable=SC2206  # intentional: space-separated list of IDs
[ -n "${SECURITY_GROUP_IDS:-}" ] && NETARGS+=(--security-group-ids $SECURITY_GROUP_IDS)

INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile Name="$INSTANCE_PROFILE" \
  --instance-initiated-shutdown-behavior terminate \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${VOLUME_GB},VolumeType=gp3,Encrypted=true}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=nf-variant-pipeline-${RUN_ID}}]" \
  --user-data "file://$USER_DATA" ${NETARGS[@]+"${NETARGS[@]}"} \
  --query 'Instances[0].InstanceId' --output text)"
rm -f "$USER_DATA"

echo "Launched $INSTANCE_ID ($INSTANCE_TYPE). It terminates itself when done."
echo "Results:  $S3_PREFIX/"
echo "Log:      $S3_PREFIX/analysis.log   (uploaded at the end)"
