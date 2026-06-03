#!/usr/bin/env bash
# One-shot deploy with plain AWS CLI (no SAM).
# Run in YOUR terminal where `aws` works and you are logged in:
#   cd to this repo, then:  bash deploy.sh
set -euo pipefail

# Load .env (GEMINI_API_KEY, INDEX_BUCKET, AWS_REGION)
if [ -f .env ]; then set -a; . ./.env; set +a; fi

BUCKET="${INDEX_BUCKET:?set INDEX_BUCKET in .env}"
REGION="${AWS_REGION:-eu-north-1}"
KEY="${GEMINI_API_KEY:?set GEMINI_API_KEY in .env}"
FN="llm-on-aws-rag"
ROLE="llm-on-aws-lambda-role"
API="llm-on-aws-api"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

echo "1/6 S3 bucket $BUCKET ..."
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || true

echo "2/6 IAM role ..."
aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document file://infra/trust-policy.json 2>/dev/null || true
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name "$ROLE" --policy-name s3read \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
echo "   waiting 10s for role to propagate ..."; sleep 10

echo "3/6 zip handler ..."
rm -rf build && mkdir build
(cd app && zip -q ../build/function.zip handler.py)

echo "4/6 Lambda ..."
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --region "$REGION" \
    --zip-file fileb://build/function.zip >/dev/null
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "Variables={GEMINI_API_KEY=$KEY,INDEX_BUCKET=$BUCKET,INDEX_KEY=index.json,TOP_K=4}" >/dev/null
else
  aws lambda create-function --function-name "$FN" --runtime python3.12 \
    --handler handler.handler --role "$ROLE_ARN" \
    --zip-file fileb://build/function.zip --timeout 30 --memory-size 256 \
    --environment "Variables={GEMINI_API_KEY=$KEY,INDEX_BUCKET=$BUCKET,INDEX_KEY=index.json,TOP_K=4}" \
    --region "$REGION" >/dev/null
fi

echo "5/6 HTTP API ..."
LAMBDA_ARN="$(aws lambda get-function --function-name "$FN" --region "$REGION" --query Configuration.FunctionArn --output text)"
API_ID="$(aws apigatewayv2 create-api --name "$API" --protocol-type HTTP --target "$LAMBDA_ARN" --region "$REGION" --query ApiId --output text)"
aws lambda add-permission --function-name "$FN" --statement-id apigw-$API_ID \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*/*" --region "$REGION" >/dev/null 2>&1 || true
ENDPOINT="$(aws apigatewayv2 get-api --api-id "$API_ID" --region "$REGION" --query ApiEndpoint --output text)"

echo "6/6 build + upload index ..."
python3 -m pip install -q boto3 >/dev/null 2>&1 || true
python3 ingest/build_index.py --upload --bucket "$BUCKET" --key index.json

echo
echo "Done. Endpoint: $ENDPOINT"
echo "Test it:"
echo "  curl -X POST $ENDPOINT -H 'Content-Type: application/json' -d '{\"question\":\"Which PLC brands does Pro-Tech work with?\"}'"
