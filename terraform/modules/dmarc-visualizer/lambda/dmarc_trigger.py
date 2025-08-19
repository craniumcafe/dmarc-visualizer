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
                # Try to find any UUID-like pattern that might be a report ID
                uuid_pattern = r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'
                match = re.search(uuid_pattern, subject, re.IGNORECASE)
                if match:
                    report_id = match.group(0)
                    print(f"Found UUID-like report_id: '{report_id}'")
                else:
                    # Try to find any hex pattern that might be truncated
                    hex_pattern = r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]+'
                    match = re.search(hex_pattern, subject, re.IGNORECASE)
                    if match:
                        report_id = match.group(0)
                        print(f"Found hex pattern report_id (possibly truncated): '{report_id}'")
                    else:
                        print("No report_id found in subject")
                        return None
    
    # Strip email domain if present (anything after @)
    if '@' in report_id:
        report_id = report_id.split('@')[0]
        print(f"Stripped email domain, report_id: '{report_id}'")
    
    # Clean up any trailing punctuation or whitespace
    report_id = report_id.strip('.,;:!?()[]{}"\'').strip()
    
    print(f"Final extracted report_id: '{report_id}' (length: {len(report_id)})")
    return report_id

def create_optimized_index_mapping(opensearch_client, index_name):
    """Create an optimized index mapping for better fuzzy matching of report IDs"""
    try:
        # Check if index already exists
        if opensearch_client.indices.exists(index=index_name):
            print(f"Index {index_name} already exists, skipping mapping creation")
            return
        
        # Create index with optimized mapping for report IDs
        mapping = {
            "mappings": {
                "properties": {
                    "report_id": {
                        "type": "text",
                        "analyzer": "standard",
                        "fields": {
                            "keyword": {
                                "type": "keyword",
                                "ignore_above": 256
                            },
                            "ngram": {
                                "type": "text",
                                "analyzer": "ngram_analyzer"
                            },
                            "edge_ngram": {
                                "type": "text",
                                "analyzer": "edge_ngram_analyzer"
                            }
                        }
                    }
                }
            },
            "settings": {
                "analysis": {
                    "analyzer": {
                        "ngram_analyzer": {
                            "type": "custom",
                            "tokenizer": "standard",
                            "filter": ["lowercase", "ngram_filter"]
                        },
                        "edge_ngram_analyzer": {
                            "type": "custom",
                            "tokenizer": "standard",
                            "filter": ["lowercase", "edge_ngram_filter"]
                        }
                    },
                    "filter": {
                        "ngram_filter": {
                            "type": "ngram",
                            "min_gram": 3,
                            "max_gram": 10
                        },
                        "edge_ngram_filter": {
                            "type": "edge_ngram",
                            "min_gram": 3,
                            "max_gram": 20
                        }
                    }
                }
            }
        }
        
        opensearch_client.indices.create(index=index_name, body=mapping)
        print(f"Created optimized index {index_name} with n-gram analyzers for better fuzzy matching")
        
    except Exception as e:
        print(f"Error creating optimized index mapping: {e}")
        # Continue with default index behavior if optimization fails

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
    print(f"Found {total_hits} hits for exact report_id: '{report_id}'")
    if total_hits > 0:
        print(f"Sample hit: {response['hits']['hits'][0]['_source'].get('report_id', 'N/A')}")
        return True
    
    # If no exact match, try fuzzy matching for truncated IDs
    print(f"Trying fuzzy matching for potentially truncated report_id: '{report_id}'")
    
    # Try prefix matching (useful for truncated IDs)
    prefix_response = opensearch_client.search(
        index=index_name,
        body={
            "query": {
                "prefix": {
                    "report_id.keyword": report_id
                }
            },
            "size": 5
        }
    )
    prefix_hits = prefix_response['hits']['total']['value']
    print(f"Found {prefix_hits} prefix matches for '{report_id}'")
    
    if prefix_hits > 0:
        # Check if any of the prefix matches are close enough
        for hit in prefix_response['hits']['hits']:
            stored_report_id = hit['_source'].get('report_id', '')
            if stored_report_id:
                # Calculate similarity - check if the stored ID starts with our truncated ID
                # and the length difference is reasonable (not more than 10 characters)
                if stored_report_id.startswith(report_id) and len(stored_report_id) - len(report_id) <= 10:
                    print(f"Found prefix match: stored='{stored_report_id}', truncated='{report_id}'")
                    return True
                # Also check if our truncated ID is a prefix of the stored ID
                elif report_id.startswith(stored_report_id[:len(report_id)]) and len(stored_report_id) - len(report_id) <= 10:
                    print(f"Found reverse prefix match: stored='{stored_report_id}', truncated='{report_id}'")
                    return True
    
    # Try n-gram matching for better partial matches
    try:
        ngram_response = opensearch_client.search(
            index=index_name,
            body={
                "query": {
                    "match": {
                        "report_id.ngram": {
                            "query": report_id,
                            "minimum_should_match": "80%"
                        }
                    }
                },
                "size": 5
            }
        )
        ngram_hits = ngram_response['hits']['total']['value']
        print(f"Found {ngram_hits} n-gram matches for '{report_id}'")
        
        if ngram_hits > 0:
            for hit in ngram_response['hits']['hits']:
                stored_report_id = hit['_source'].get('report_id', '')
                if stored_report_id:
                    # Check if this is a good match
                    if len(stored_report_id) >= len(report_id) and stored_report_id.startswith(report_id[:min(20, len(report_id))]):
                        print(f"Found n-gram match: stored='{stored_report_id}', truncated='{report_id}'")
                        return True
    except Exception as e:
        print(f"N-gram search failed (index may not have n-gram analyzer): {e}")
    
    # Try fuzzy matching with edit distance
    fuzzy_response = opensearch_client.search(
        index=index_name,
        body={
            "query": {
                "fuzzy": {
                    "report_id.keyword": {
                        "value": report_id,
                        "fuzziness": "AUTO",
                        "max_expansions": 10
                    }
                }
            },
            "size": 5
        }
    )
    fuzzy_hits = fuzzy_response['hits']['total']['value']
    print(f"Found {fuzzy_hits} fuzzy matches for '{report_id}'")
    
    if fuzzy_hits > 0:
        # Check if any fuzzy matches are close enough
        for hit in fuzzy_response['hits']['hits']:
            stored_report_id = hit['_source'].get('report_id', '')
            if stored_report_id:
                # Calculate Levenshtein distance manually for better control
                distance = levenshtein_distance(report_id, stored_report_id)
                max_allowed_distance = min(len(report_id) // 4, 5)  # Allow up to 25% of length or 5 chars
                
                if distance <= max_allowed_distance:
                    print(f"Found fuzzy match: stored='{stored_report_id}', truncated='{report_id}', distance={distance}")
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

def levenshtein_distance(s1, s2):
    """Calculate the Levenshtein distance between two strings"""
    if len(s1) < len(s2):
        return levenshtein_distance(s2, s1)
    
    if len(s2) == 0:
        return len(s1)
    
    previous_row = list(range(len(s2) + 1))
    for i, c1 in enumerate(s1):
        current_row = [i + 1]
        for j, c2 in enumerate(s2):
            insertions = previous_row[j + 1] + 1
            deletions = current_row[j] + 1
            substitutions = previous_row[j] + (c1 != c2)
            current_row.append(min(insertions, deletions, substitutions))
        previous_row = current_row
    
    return previous_row[-1]

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
    
    # Try to create optimized index mapping for better fuzzy matching
    try:
        # Use a base index name without wildcards for mapping creation
        base_index_name = OPENSEARCH_INDEX.replace('*', '2025-01-01')  # Use a sample date
        create_optimized_index_mapping(opensearch_client, base_index_name)
    except Exception as e:
        print(f"Note: Could not create optimized index mapping: {e}")
        print("Continuing with default index behavior...")
    
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
        print(f"Report ID length: {len(report_id)} characters")

        # Retry a few times in case of OpenSearch delay
        found = False
        for attempt in range(20):  # Increased retry count
            print(f"Attempt {attempt + 1}/20: Checking for report_id '{report_id}'")
            print(f"  Report ID length: {len(report_id)} characters")
            print(f"  Search index: {OPENSEARCH_INDEX}")
            
            if is_report_in_opensearch(report_id, opensearch_client, OPENSEARCH_INDEX):
                found = True
                print(f"SUCCESS: Report {report_id} found in OpenSearch on attempt {attempt + 1}")
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
            
            # Also try to find similar report IDs for debugging
            print(f"Searching for similar report IDs to '{report_id}' for debugging:")
            try:
                similar_response = opensearch_client.search(
                    index=OPENSEARCH_INDEX,
                    body={
                        "query": {
                            "bool": {
                                "should": [
                                    {"prefix": {"report_id.keyword": report_id[:10]}},  # First 10 chars
                                    {"prefix": {"report_id.keyword": report_id[:15]}}, # First 15 chars
                                    {"prefix": {"report_id.keyword": report_id[:20]}}  # First 20 chars
                                ]
                            }
                        },
                        "size": 10,
                        "_source": ["report_id", "@timestamp"]
                    }
                )
                similar_hits = similar_response['hits']['total']['value']
                print(f"Found {similar_hits} similar report IDs:")
                for hit in similar_response['hits']['hits']:
                    similar_id = hit['_source'].get('report_id', 'N/A')
                    timestamp = hit['_source'].get('@timestamp', 'N/A')
                    print(f"  Similar: {similar_id} (timestamp: {timestamp})")
            except Exception as e:
                print(f"Error searching for similar report IDs: {e}")

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

def test_fuzzy_matching():
    """Test function to validate fuzzy matching logic"""
    print("Testing fuzzy matching logic...")
    
    # Test case from the user's example
    truncated_id = "bc663a43-570e-4ce2-a5ee-4e9758998"
    full_id = "bc663a43-570e-4ce2-a5ee-4e9758998888"
    
    print(f"Truncated ID: '{truncated_id}' (length: {len(truncated_id)})")
    print(f"Full ID: '{full_id}' (length: {len(full_id)})")
    
    # Test prefix matching
    if full_id.startswith(truncated_id):
        print(f"✓ Prefix match: '{full_id}' starts with '{truncated_id}'")
    else:
        print(f"✗ No prefix match")
    
    # Test Levenshtein distance
    distance = levenshtein_distance(truncated_id, full_id)
    print(f"Levenshtein distance: {distance}")
    
    # Test similarity logic
    length_diff = len(full_id) - len(truncated_id)
    max_allowed_distance = min(len(truncated_id) // 4, 5)
    
    print(f"Length difference: {length_diff}")
    print(f"Max allowed distance: {max_allowed_distance}")
    
    if length_diff <= 10:
        print(f"✓ Length difference ({length_diff}) is within acceptable range (≤10)")
    else:
        print(f"✗ Length difference ({length_diff}) exceeds acceptable range (≤10)")
    
    if distance <= max_allowed_distance:
        print(f"✓ Edit distance ({distance}) is within acceptable range (≤{max_allowed_distance})")
    else:
        print(f"✗ Edit distance ({distance}) exceeds acceptable range (≤{max_allowed_distance})")
    
    print("Fuzzy matching test completed.")

# Uncomment the line below to test fuzzy matching when running locally
# if __name__ == "__main__":
#     test_fuzzy_matching() 