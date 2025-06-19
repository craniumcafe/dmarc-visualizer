import os
import json
import boto3
import time
import email
from email import policy
import re
from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

def extract_report_id(subject):
    if not subject:
        return None
        
    # Normalize newlines to spaces and collapse multiple spaces
    subject = ' '.join(subject.split())
    
    # Try to match <...> or {...}
    match = re.search(r'Report-ID:\s*[<{]([^>}]+)[>}]', subject, re.IGNORECASE)
    if match:
        report_id = match.group(1)
    else:
        # Try to match Report-ID: followed by non-whitespace
        match = re.search(r'Report-ID:\s*([^\s]+)', subject, re.IGNORECASE)
        if match:
            report_id = match.group(1)
        else:
            # Try to match just the ID after "Report-ID" anywhere in the subject
            match = re.search(r'Report-ID[:\s]+(.+?)(?:\s|$)', subject, re.IGNORECASE)
            if match:
                report_id = match.group(1).strip()
            else:
                return None
    
    # Strip email domain if present (anything after @)
    if '@' in report_id:
        report_id = report_id.split('@')[0]
    
    return report_id

def is_report_in_opensearch(report_id, opensearch_client, index_name):
    response = opensearch_client.search(
        index=index_name,
        body={
            "query": {
                "term": {
                    "report_id.keyword": report_id
                }
            }
        }
    )
    return response['hits']['total']['value'] > 0

def extract_report_id_from_s3_object(s3, bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    raw_email = obj['Body'].read().decode('utf-8')
    msg = email.message_from_string(raw_email, policy=policy.default)
    subject = msg['Subject']
    if not subject:
        print(f"Subject header missing in {key}")
        return None
    return extract_report_id(subject)

def lambda_handler(event, context):
    s3 = boto3.client('s3')
    ecs = boto3.client('ecs')

    # --- FILL THESE IN ---
    OPENSEARCH_HOST = os.environ['OPENSEARCH_HOST']  # e.g. 'search-domain-xxxx.us-east-1.es.amazonaws.com'
    OPENSEARCH_INDEX = os.environ['OPENSEARCH_INDEX']  # e.g. 'dmarc_aggregate-*'

    credentials = boto3.Session().get_credentials()
    region = os.environ['AWS_REGION']

    auth = AWSV4SignerAuth(credentials, region)

    # Connect to OpenSearch
    opensearch_client = OpenSearch(
        hosts=[{'host': OPENSEARCH_HOST, 'port': 443}],
        http_auth=auth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection
    )

    bucket = os.environ['BUCKET_NAME']
    prefix = os.environ['S3_PATH']
    cluster_arn = os.environ['CLUSTER_ARN']
    service_name = os.environ.get('SERVICE_NAME', 'parsedmarc')

    # List all files in the S3 prefix
    paginator = s3.get_paginator('list_objects_v2')
    files = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            key = obj['Key']
            if "aggregate/" not in key:
                files.append(key)
            else:
                print(f"Skipping output/aggregate file: {key}")

    if not files:
        print('No files to process.')
        # Optionally scale down service if no files left
        ecs.update_service(
            cluster=cluster_arn,
            service=service_name,
            desiredCount=0
        )
        print(f"No files to process. Scaled service '{service_name}' down to 0.")
        return {'status': 'no_files'}

    print(f'Found {len(files)} files to process.')

    # Scale up service if not already running
    response = ecs.describe_services(cluster=cluster_arn, services=[service_name])
    running_count = response['services'][0]['runningCount']
    if running_count == 0:
        ecs.update_service(
            cluster=cluster_arn,
            service=service_name,
            desiredCount=1
        )
        print(f"Started '{service_name}' service task.")
    else:
        print(f"Service '{service_name}' task already running.")

    # For each file, extract report_id, check OpenSearch, and delete if found
    for key in files:
        report_id = extract_report_id_from_s3_object(s3, bucket, key)
        if not report_id:
            print(f"Could not extract report_id from {key}, skipping delete.")
            continue

        # Retry a few times in case of OpenSearch delay
        found = False
        for attempt in range(5):
            if is_report_in_opensearch(report_id, opensearch_client, OPENSEARCH_INDEX):
                found = True
                break
            else:
                print(f"Report {report_id} not found in OpenSearch. Retrying...")
                time.sleep(10)
        if found:
            print(f"Report {report_id} found in OpenSearch. Deleting {key} from S3...")
            s3.delete_object(Bucket=bucket, Key=key)
        else:
            print(f"Report {report_id} not found in OpenSearch after retries. Skipping delete.")

    print('All processed files checked and deleted if found in OpenSearch.')

    # After processing, check if any files remain. If not, scale service down to 0.
    paginator = s3.get_paginator('list_objects_v2')
    remaining_files = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            remaining_files.append(obj['Key'])

    if not remaining_files:
        ecs.update_service(
            cluster=cluster_arn,
            service=service_name,
            desiredCount=0
        )
        print(f"No files remain. Scaled service '{service_name}' down to 0.")
    else:
        print(f"{len(remaining_files)} files remain. Service '{service_name}' remains running.")

    return {'status': 'success', 'processed_files': files} 