import urllib, json, sys
import getpass
# import requests # 'pip install requests'
import boto3 # AWS SDK for Python (Boto3) 'pip install boto3'
from botocore.exceptions import ClientError

ec2_connection = boto3.client('ec2', region_name='us-east-2')

try:
    response = ec2_connection.start_instances(InstanceIds=[
        'i-0417debb8c8b1f5f6',
        'i-04d1314d2bf5b926f'
        ])
    print(response)
except ClientError as e:
    print(e)


