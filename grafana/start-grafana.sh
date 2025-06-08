#!/bin/sh
echo "==== ENVIRONMENT VARIABLES ===="
env | grep AWS
echo "==== END ENVIRONMENT VARIABLES ===="

# Validate OpenSearch connectivity
echo "==== TESTING OPENSEARCH CONNECTIVITY ===="
awscurl --service es --region us-east-1 -XGET https://search-dmarc-domain-qlmy6lk2nnxuip4tb3q6m2wuka.us-east-1.es.amazonaws.com/
echo "==== END OPENSEARCH CONNECTIVITY TEST ===="

exec grafana server
