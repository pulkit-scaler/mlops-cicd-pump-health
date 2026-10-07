#!/usr/bin/env bash
# Deletes everything infra/up.sh created, and every image the pipeline pushed.
#
#     infra/down.sh
#
# Safe to run twice. It leaves alone what the session itself created, GitHub's
# identity provider and the deploy role, which the session deletes on its own.
# The task execution role ecsTaskExecutionRole is also left in place, because
# it costs nothing and every ECS deployment uses it.
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/lookup.sh || exit 1
SECONDS=0

# The service, then the load balancer, then the target group
STATUS=$(aws ecs describe-services --cluster mlops-cluster --services pump-health --query 'services[0].status' --output text 2>/dev/null)
if [ "$STATUS" = ACTIVE ]; then
  aws ecs delete-service --cluster mlops-cluster --service pump-health --force >/dev/null
  aws ecs wait services-inactive --cluster mlops-cluster --services pump-health
fi
[ -n "$ALB_ARN" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" &&
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
if [ -n "$TG_ARN" ]; then
  # The listener goes a few seconds after the load balancer, so the delete is retried.
  for try in $(seq 12); do aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null && break; sleep 10; done
fi
echo "service and load balancer deleted"

# Every task definition revision, the cluster, the logs and the registry with its images
for td in $(aws ecs list-task-definitions --family-prefix pump-health --query 'taskDefinitionArns' --output text); do
  aws ecs deregister-task-definition --task-definition "$td" >/dev/null
done
sleep 5
ARNS=$(aws ecs list-task-definitions --family-prefix pump-health --status INACTIVE --query 'taskDefinitionArns' --output text)
[ -n "$ARNS" ] && aws ecs delete-task-definitions --task-definitions $ARNS >/dev/null
aws ecs delete-cluster --cluster mlops-cluster >/dev/null 2>&1
aws logs delete-log-group --log-group-name /ecs/pump-health 2>/dev/null
aws ecr delete-repository --repository-name pump-health --force >/dev/null 2>&1
echo "task definitions, cluster, logs and registry deleted"

# The network. The load balancer's network interfaces linger for a while, so each delete is retried.
for sg in "$TASK_SG" "$ALB_SG"; do
  [ -z "$sg" ] && continue
  for try in $(seq 30); do aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 && break; sleep 10; done
done
if [ -n "$RT_ID" ]; then
  for a in $(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
             --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do
    aws ec2 disassociate-route-table --association-id "$a"
  done
  aws ec2 delete-route-table --route-table-id "$RT_ID"
fi
if [ -n "$IGW_ID" ]; then
  [ -n "$VPC_ID" ] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi
for s in "$SUBNET_A" "$SUBNET_B"; do [ -n "$s" ] && aws ec2 delete-subnet --subnet-id "$s"; done
[ -n "$VPC_ID" ] && aws ec2 delete-vpc --vpc-id "$VPC_ID"
echo "network deleted, ${SECONDS} s in all"
