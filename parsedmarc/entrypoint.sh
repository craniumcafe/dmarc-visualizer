#!/bin/sh
set -e

cat > /parsedmarc.ini <<EOF
[general]
save_aggregate = True
save_forensic = True
debug = True
log_file = /tmp/parsedmarc.log
strip_attachment_payloads = True
n_procs = 2
output = /tmp
aggregate_json_filename = aggregate.json
forensic_json_filename = forensic.json

[opensearch]
hosts = http://localhost:9200
ssl = False
# Using SigV4 proxy, no username/password needed

[s3]
bucket = ses-email-archive-d99f0d87
path = craniumcafe.com/dmarc
region_name = us-east-1
EOF

# Download S3 files and run parsedmarc
mkdir -p /tmp/dmarc
aws s3 sync "s3://ses-email-archive-d99f0d87/craniumcafe.com/dmarc" /tmp/dmarc
parsedmarc -c /parsedmarc.ini /tmp/dmarc/*

# Print the aggregate JSON output to stdout for CloudWatch logging
if [ -f /tmp/aggregate.json ]; then
  echo "--- AGGREGATE JSON OUTPUT ---"
  cat /tmp/aggregate.json
  echo "--- END AGGREGATE JSON OUTPUT ---"
fi