import os
import json
import boto3
import time

def lambda_handler(event, context):
    s3 = boto3.client('s3')
    ecs = boto3.client('ecs')

    bucket = os.environ['BUCKET_NAME']
    prefix = os.environ['S3_PATH']
    cluster_arn = os.environ['CLUSTER_ARN']
    task_def_arn = os.environ['TASK_DEF_ARN']
    subnets = os.environ['SUBNETS'].split(',')
    security_groups = os.environ['SECURITY_GROUPS'].split(',')

    # List all files in the S3 prefix
    paginator = s3.get_paginator('list_objects_v2')
    files = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            files.append(obj['Key'])

    if not files:
        print('No files to process.')
        return {'status': 'no_files'}

    print(f'Found {len(files)} files to process.')

    # Start a single ECS Fargate task (no overrides)
    response = ecs.run_task(
        cluster=cluster_arn,
        taskDefinition=task_def_arn,
        launchType='FARGATE',
        count=1,
        platformVersion='LATEST',
        networkConfiguration={
            'awsvpcConfiguration': {
                'subnets': subnets,
                'securityGroups': security_groups,
                'assignPublicIp': 'ENABLED'
            }
        }
    )
    task_arn = response['tasks'][0]['taskArn']
    print(f'Started ECS task: {task_arn}')

    # Wait for ECS task to complete
    waiter = ecs.get_waiter('tasks_stopped')
    waiter.wait(cluster=cluster_arn, tasks=[task_arn])
    print('ECS task completed.')

    # Delete processed files from S3
    for key in files:
        print(f'Deleting {key} from S3...')
        s3.delete_object(Bucket=bucket, Key=key)

    print('All processed files deleted.')

    return {'status': 'success', 'processed_files': files} 