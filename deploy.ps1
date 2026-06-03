# Manual deploy with plain AWS CLI (no SAM required).
# Run from the repo root in a terminal where `aws` works and you are logged in.
# Edit the three values below, then: powershell -ExecutionPolicy Bypass -File .\deploy.ps1

$ErrorActionPreference = 'Stop'

# ---- edit these ----
$Bucket   = "llm-on-aws-index-CHANGE-ME"   # must be globally unique
$GeminiKey = $env:GEMINI_API_KEY            # or paste the key as a string
$Region   = "eu-north-1"                    # Stockholm; change if you prefer
# --------------------

$Fn       = "llm-on-aws-rag"
$Role     = "llm-on-aws-lambda-role"
$ApiName  = "llm-on-aws-api"
$AccountId = (aws sts get-caller-identity --query Account --output text)

if (-not $GeminiKey) { throw "Set GEMINI_API_KEY in your env or hardcode it in this script." }

Write-Host "1/6 creating S3 bucket $Bucket ..."
aws s3api create-bucket --bucket $Bucket --region $Region `
  --create-bucket-configuration LocationConstraint=$Region 2>$null

Write-Host "2/6 creating IAM role ..."
aws iam create-role --role-name $Role `
  --assume-role-policy-document file://infra/trust-policy.json 2>$null
aws iam attach-role-policy --role-name $Role `
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
$RoleArn = (aws iam get-role --role-name $Role --query Role.Arn --output text)
Start-Sleep -Seconds 10  # let the role propagate

Write-Host "3/6 zipping handler ..."
if (Test-Path build) { Remove-Item build -Recurse -Force }
New-Item -ItemType Directory build | Out-Null
Compress-Archive -Path app\handler.py -DestinationPath build\function.zip -Force

Write-Host "4/6 creating Lambda ..."
$envVars = "Variables={GEMINI_API_KEY=$GeminiKey,INDEX_BUCKET=$Bucket,INDEX_KEY=index.json,TOP_K=4}"
aws lambda create-function --function-name $Fn --runtime python3.12 `
  --handler handler.handler --role $RoleArn `
  --zip-file fileb://build/function.zip `
  --timeout 30 --memory-size 256 --environment $envVars --region $Region

# give the function read access to the bucket
$s3policy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::' + $Bucket + '/*"}]}'
aws iam put-role-policy --role-name $Role --policy-name s3read --policy-document $s3policy

Write-Host "5/6 creating HTTP API ..."
$LambdaArn = (aws lambda get-function --function-name $Fn --region $Region --query Configuration.FunctionArn --output text)
$ApiId = (aws apigatewayv2 create-api --name $ApiName --protocol-type HTTP --target $LambdaArn --region $Region --query ApiId --output text)
aws lambda add-permission --function-name $Fn --statement-id apigw `
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com `
  --source-arn "arn:aws:execute-api:${Region}:${AccountId}:${ApiId}/*/*" --region $Region

$ApiEndpoint = (aws apigatewayv2 get-api --api-id $ApiId --region $Region --query ApiEndpoint --output text)

Write-Host "6/6 building + uploading the index ..."
python ingest/build_index.py --upload --bucket $Bucket --key index.json

Write-Host ""
Write-Host "Done. Test it with:"
Write-Host "  curl -X POST $ApiEndpoint -H 'Content-Type: application/json' -d '{\"question\":\"What does Pro-Tech do?\"}'"
