#!/bin/sh
set -e

# Install required packages for email processing
apk add --no-cache python3-dev py3-pip
pip3 install email-validator

cat > /extract_attachments.py <<EOF
import email
import os
import sys
from email import policy

def extract_attachments(email_file, output_dir):
    with open(email_file, 'r') as f:
        msg = email.message_from_file(f, policy=policy.default)
    
    for part in msg.walk():
        if part.get_content_maintype() == 'multipart':
            continue
        if part.get('Content-Disposition') is None:
            continue
            
        filename = part.get_filename()
        if not filename:
            continue
            
        filepath = os.path.join(output_dir, os.path.basename(email_file) + '.xml')
        with open(filepath, 'wb') as f:
            f.write(part.get_payload(decode=True))
            print(f"Extracted {filepath}")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python3 extract_attachments.py <email_file> <output_dir>")
        sys.exit(1)
    
    extract_attachments(sys.argv[1], sys.argv[2])
EOF

cat > /parsedmarc.ini <<EOF
[general]
save_aggregate = True
save_forensic = True
debug = True
log_file = /tmp/parsedmarc.log
strip_attachment_payloads = False
extract_emails = True
n_procs = 2

[opensearch]
hosts = http://localhost:9200
ssl = False
# Using SigV4 proxy, no username/password needed

EOF

# Download S3 files and process them
mkdir -p /tmp/dmarc
mkdir -p /tmp/dmarc_extracted

# Download files from S3
aws s3 sync "s3://ses-email-archive-d99f0d87/craniumcafe.com/dmarc" /tmp/dmarc --exclude "aggregate/*"

# Process each file
for file in /tmp/dmarc/*; do
    if [ -f "$file" ]; then
        # Try to extract attachments first (in case it's an email)
        python3 /extract_attachments.py "$file" /tmp/dmarc_extracted || true
    fi
done

# Process both original files and extracted attachments
parsedmarc -c /parsedmarc.ini /tmp/dmarc/* /tmp/dmarc_extracted/*