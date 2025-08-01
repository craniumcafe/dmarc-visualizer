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
    
    print(f"Processing subject: '{subject}'")
    
    # Try to match <...> or {...}
    match = re.search(r'Report-ID:\s*[<{]([^>}]+)[>}]', subject, re.IGNORECASE)
    if match:
        report_id = match.group(1)
        print(f"Found report_id in brackets: '{report_id}'")
    else:
        # Try to match Report-ID: followed by non-whitespace (handles Report-ID:2025.07.31.1650389751)
        match = re.search(r'Report-ID:\s*([^\s]+)', subject, re.IGNORECASE)
        if match:
            report_id = match.group(1)
            print(f"Found report_id after colon: '{report_id}'")
        else:
            # Try to match just the ID after "Report-ID" anywhere in the subject
            match = re.search(r'Report-ID[:\s]+(.+?)(?:\s|$)', subject, re.IGNORECASE)
            if match:
                report_id = match.group(1).strip()
                print(f"Found report_id with space: '{report_id}'")
            else:
                print("No report_id found in subject")
                return None
    
    # Strip email domain if present (anything after @)
    if '@' in report_id:
        report_id = report_id.split('@')[0]
        print(f"Stripped email domain, report_id: '{report_id}'")
    
    print(f"Final extracted report_id: '{report_id}'")
    return report_id

def is_report_in_opensearch(report_id, opensearch_client, index_name):
    print(f"Searching for report_id: '{report_id}' in index: {index_name}")
    
    # Try exact match first
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
    total_hits = response['hits']['total']['value']
    print(f"Found {total_hits} hits for report_id: '{report_id}'")
    if total_hits > 0:
        print(f"Sample hit: {response['hits']['hits'][0]['_source'].get('report_id', 'N/A')}")
        return True
    
    # If no exact match, try searching for just the numeric part (parsedmarc might store only the numeric part)
    if '.' in report_id:
        # Try searching for just the numeric part after the last dot
        numeric_part = report_id.split('.')[-1]
        print(f"Trying exact match with numeric part: '{numeric_part}'")
        response = opensearch_client.search(
            index=index_name,
            body={
                "query": {
                    "term": {
                        "report_id.keyword": numeric_part
                    }
                }
            }
        )
        total_hits = response['hits']['total']['value']
        print(f"Found {total_hits} hits for numeric part '{numeric_part}'")
        if total_hits > 0:
            print(f"Sample hit: {response['hits']['hits'][0]['_source'].get('report_id', 'N/A')}")
            return True
    
    return False

def extract_report_id_from_s3_object(s3, bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    raw_email = obj['Body'].read().decode('utf-8')
    msg = email.message_from_string(raw_email, policy=policy.default)
    subject = msg['Subject']
    if not subject:
        print(f"Subject header missing in {key}")
        return None
    return extract_report_id(subject)

def list_recent_report_ids(opensearch_client, index_name, limit=10):
    """List recent report IDs in OpenSearch for debugging"""
    try:
        response = opensearch_client.search(
            index=index_name,
            body={
                "size": limit,
                "sort": [{"@timestamp": {"order": "desc"}}],
                "_source": ["report_id", "@timestamp"]
            }
        )
        print(f"Recent report IDs in OpenSearch:")
        for hit in response['hits']['hits']:
            report_id = hit['_source'].get('report_id', 'N/A')
            timestamp = hit['_source'].get('@timestamp', 'N/A')
            print(f"  {report_id} (timestamp: {timestamp})")
    except Exception as e:
        print(f"Error listing recent report IDs: {e}")

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
    
    # List recent report IDs for debugging
    list_recent_report_ids(opensearch_client, OPENSEARCH_INDEX)
    
    # Also check if there are any recent documents in the index
    try:
        response = opensearch_client.search(
            index=OPENSEARCH_INDEX,
            body={
                "size": 1,
                "sort": [{"@timestamp": {"order": "desc"}}],
                "_source": ["@timestamp"]
            }
        )
        if response['hits']['total']['value'] > 0:
            latest_timestamp = response['hits']['hits'][0]['_source'].get('@timestamp', 'N/A')
            print(f"Latest document in OpenSearch: {latest_timestamp}")
        else:
            print("No documents found in OpenSearch index")
    except Exception as e:
        print(f"Error checking latest document: {e}")

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
    desired_count = response['services'][0]['desiredCount']
    print(f"Service '{service_name}' status: {running_count} running, {desired_count} desired")
    
    if running_count == 0:
        ecs.update_service(
            cluster=cluster_arn,
            service=service_name,
            desiredCount=1
        )
        print(f"Started '{service_name}' service task.")
    else:
        print(f"Service '{service_name}' task already running.")
        
    # Wait a bit for the service to start processing if it was just started
    if running_count == 0:
        print("Waiting 30 seconds for parsedmarc service to start processing...")
        time.sleep(30)
    
    # Check if there are any running tasks and their status
    try:
        tasks_response = ecs.list_tasks(cluster=cluster_arn, serviceName=service_name)
        if tasks_response['taskArns']:
            task_arn = tasks_response['taskArns'][0]
            task_details = ecs.describe_tasks(cluster=cluster_arn, tasks=[task_arn])
            task_status = task_details['tasks'][0]['lastStatus']
            print(f"Parsedmarc task status: {task_status}")
            
            # Check if task is running and healthy
            if task_status == 'RUNNING':
                print("Parsedmarc task is running and should be processing files")
            else:
                print(f"Parsedmarc task is not running properly. Status: {task_status}")
        else:
            print("No parsedmarc tasks found")
    except Exception as e:
        print(f"Error checking task status: {e}")

    # For each file, extract report_id, check OpenSearch, and delete if found
    for key in files:
        report_id = extract_report_id_from_s3_object(s3, bucket, key)
        if not report_id:
            print(f"Could not extract report_id from {key}, skipping delete.")
            continue
        
        print(f"Extracted report_id: '{report_id}' from file: {key}")

        # Retry a few times in case of OpenSearch delay
        found = False
        for attempt in range(20):  # Increased retry count
            print(f"Attempt {attempt + 1}/20: Checking for report_id '{report_id}'")
            if is_report_in_opensearch(report_id, opensearch_client, OPENSEARCH_INDEX):
                found = True
                break
            else:
                print(f"Report {report_id} not found in OpenSearch. Retrying in 15 seconds...")
                time.sleep(15)  # Increased wait time
        if found:
            print(f"Report {report_id} found in OpenSearch. Deleting {key} from S3...")
            s3.delete_object(Bucket=bucket, Key=key)
        else:
            print(f"Report {report_id} not found in OpenSearch after retries. Skipping delete.")
            # List recent report IDs again to see what's available
            print("Listing recent report IDs after failed search:")
            list_recent_report_ids(opensearch_client, OPENSEARCH_INDEX, limit=5)

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