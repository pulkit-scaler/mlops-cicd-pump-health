#!/usr/bin/env bash
# Stands up everything the pipeline deploys to, the same pieces the ECS session
# built in the console, made from the command line.
#
#     infra/up.sh
#
# It makes the network, the load balancer, the cluster, the ECR repository, the
# first image and the service. It does not make anything that lets GitHub into
# AWS. That is done in the session.
#
# Safe to run twice. Anything that already exists is left alone. Needs the AWS
# CLI signed in to us-east-1, and Docker for the first image.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p scratch
source infra/lookup.sh
tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2}]"; }
SECONDS=0

# --- The network: a VPC, two public subnets, the route to the internet, two security groups
[ -z "$VPC_ID" ] && aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(tag vpc mlops-vpc)" >/dev/null
source infra/lookup.sh
[ -z "$SUBNET_A" ] && aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a --tag-specifications "$(tag subnet mlops-public-a)" >/dev/null
[ -z "$SUBNET_B" ] && aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 \
  --availability-zone us-east-1b --tag-specifications "$(tag subnet mlops-public-b)" >/dev/null
[ -z "$IGW_ID" ] && aws ec2 create-internet-gateway --tag-specifications "$(tag internet-gateway mlops-igw)" >/dev/null
[ -z "$RT_ID" ] && aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag route-table mlops-public-rt)" >/dev/null
source infra/lookup.sh
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
for s in "$SUBNET_A" "$SUBNET_B"; do
  aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$s" >/dev/null 2>&1 || true
done
[ -z "$ALB_SG" ] && aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name mlops-alb-sg \
  --description "pump-health load balancer, HTTP from anywhere" >/dev/null
[ -z "$TASK_SG" ] && aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name mlops-task-sg \
  --description "pump-health tasks, port 8000 from the load balancer only" >/dev/null
source infra/lookup.sh
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" --protocol tcp --port 8000 --source-group "$ALB_SG" >/dev/null 2>&1 || true
echo "network ready"

# --- The execution role ECS uses to pull the image and write logs, and the registry
aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1 ||
  aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws ecr describe-repositories --repository-names pump-health >/dev/null 2>&1 ||
  aws ecr create-repository --repository-name pump-health --image-tag-mutability IMMUTABLE >/dev/null
echo "registry pump-health ready, tags immutable"

# --- The cluster, the log group, the target group, the load balancer and its listener
aws ecs create-cluster --cluster-name mlops-cluster >/dev/null
aws logs create-log-group --log-group-name /ecs/pump-health 2>/dev/null || true
aws logs put-retention-policy --log-group-name /ecs/pump-health --retention-in-days 1
[ -z "$TG_ARN" ] && aws elbv2 create-target-group --name pump-health-tg --vpc-id "$VPC_ID" \
  --protocol HTTP --port 8000 --target-type ip --health-check-path /health \
  --health-check-interval-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 3 >/dev/null
[ -z "$ALB_ARN" ] && aws elbv2 create-load-balancer --name pump-health-alb --type application \
  --scheme internet-facing --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$ALB_SG" >/dev/null
# Waiting by name also covers the first seconds, when AWS does not list the new load balancer yet
aws elbv2 wait load-balancer-available --names pump-health-alb
source infra/lookup.sh
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
[ "$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'length(Listeners)' --output text)" = 0 ] &&
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" >/dev/null
echo "load balancer ready"

# --- The first image, tagged with the current commit, if the registry does not have it yet
SHA=$(git rev-parse HEAD)
if ! aws ecr describe-images --repository-name pump-health --image-ids imageTag="$SHA" >/dev/null 2>&1; then
  aws ecr get-login-password | docker login -u AWS --password-stdin "$ECR_REGISTRY" >/dev/null 2>&1
  docker build -q --platform linux/amd64 --build-arg GIT_SHA="$SHA" -t "$ECR_URI:$SHA" . >/dev/null
  docker push -q "$ECR_URI:$SHA" >/dev/null
  echo "pushed pump-health:${SHA:0:7}"
fi

# --- The task definition and the service, with the deployment circuit breaker on
cat > scratch/taskdef.json <<JSON
{
  "family": "pump-health",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "runtimePlatform": {"cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX"},
  "executionRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole",
  "containerDefinitions": [{
    "name": "pump-health",
    "image": "${ECR_URI}:${SHA}",
    "essential": true,
    "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
    "logConfiguration": {"logDriver": "awslogs", "options": {
      "awslogs-group": "/ecs/pump-health", "awslogs-region": "us-east-1", "awslogs-stream-prefix": "ecs"}}
  }]
}
JSON
STATUS=$(aws ecs describe-services --cluster mlops-cluster --services pump-health --query 'services[0].status' --output text 2>/dev/null || true)
if [ "$STATUS" != ACTIVE ]; then
  aws ecs register-task-definition --cli-input-json file://scratch/taskdef.json >/dev/null
  aws ecs create-service --cluster mlops-cluster --service-name pump-health --task-definition pump-health \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=pump-health,containerPort=8000" \
    --health-check-grace-period-seconds 30 \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" >/dev/null
fi
aws ecs wait services-stable --cluster mlops-cluster --services pump-health
echo "service pump-health stable in mlops-cluster, ${SECONDS} s in all"
echo "http://$ALB_DNS"
