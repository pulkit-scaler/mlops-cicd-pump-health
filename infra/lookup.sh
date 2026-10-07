# Finds this project's AWS resources by name and exports their IDs.
#
#     source infra/lookup.sh
#
# A resource that does not exist yet gives an empty variable.
q() { v=$(aws "$@" --output text 2>/dev/null); [ "$v" = None ] && v=; echo "$v"; }

# The CLI must be signed in first. q hides errors, so with expired credentials
# every ID below would come back empty, and up.sh would try to create it all
# again. An SSO profile gets its sign-in page opened, when there is a terminal.
if [ -z "${LOOKUP_SIGNED_IN:-}" ]; then
  if ! err=$(aws sts get-caller-identity 2>&1 >/dev/null); then
    prof=${AWS_PROFILE:-default}
    if [ -t 0 ] && [ -n "$(aws configure get sso_session --profile "$prof" 2>/dev/null)$(aws configure get sso_start_url --profile "$prof" 2>/dev/null)" ]; then
      echo "The AWS CLI is not signed in as profile $prof. Opening the sign-in page." >&2
      aws sso login --profile "$prof" >&2 && err=$(aws sts get-caller-identity 2>&1 >/dev/null) && err=
    fi
    if [ -n "$err" ]; then
      sso=$(for p in $(aws configure list-profiles 2>/dev/null); do
              if [ -n "$(aws configure get sso_session --profile "$p" 2>/dev/null)$(aws configure get sso_start_url --profile "$p" 2>/dev/null)" ]; then echo "$p"; fi
            done | paste -sd ' ' -)
      cat >&2 <<EOF
The AWS CLI is not signed in (profile $prof):
${err#*: }
Sign in, then run this again:
    aws login                                   # your own account
    aws sso login --profile NAME                # a company account with SSO
    export AWS_PROFILE=NAME                     #   and use that profile
SSO profiles on this machine: ${sso:-none}
EOF
      return 1 2>/dev/null || exit 1
    fi
  fi
  LOOKUP_SIGNED_IN=1
fi

# owner/name of this clone's GitHub repository, from its remote
export GITHUB_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')
export AWS_ACCOUNT_ID=$(q sts get-caller-identity --query Account)
export ECR_REGISTRY=${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
export ECR_URI=${ECR_REGISTRY}/pump-health

# The network
export VPC_ID=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=mlops-vpc --query 'Vpcs[0].VpcId')
export SUBNET_A=$(q ec2 describe-subnets --filters Name=tag:Name,Values=mlops-public-a --query 'Subnets[0].SubnetId')
export SUBNET_B=$(q ec2 describe-subnets --filters Name=tag:Name,Values=mlops-public-b --query 'Subnets[0].SubnetId')
export IGW_ID=$(q ec2 describe-internet-gateways --filters Name=tag:Name,Values=mlops-igw --query 'InternetGateways[0].InternetGatewayId')
export RT_ID=$(q ec2 describe-route-tables --filters Name=tag:Name,Values=mlops-public-rt --query 'RouteTables[0].RouteTableId')
export ALB_SG=$(q ec2 describe-security-groups --filters Name=group-name,Values=mlops-alb-sg Name=vpc-id,Values="${VPC_ID:-none}" --query 'SecurityGroups[0].GroupId')
export TASK_SG=$(q ec2 describe-security-groups --filters Name=group-name,Values=mlops-task-sg Name=vpc-id,Values="${VPC_ID:-none}" --query 'SecurityGroups[0].GroupId')

# The load balancer in front of the service
export TG_ARN=$(q elbv2 describe-target-groups --names pump-health-tg --query 'TargetGroups[0].TargetGroupArn')
export ALB_ARN=$(q elbv2 describe-load-balancers --names pump-health-alb --query 'LoadBalancers[0].LoadBalancerArn')
export ALB_DNS=$(q elbv2 describe-load-balancers --names pump-health-alb --query 'LoadBalancers[0].DNSName')

# GitHub's identity provider, created in the session, not by up.sh
export OIDC_ARN=$(q iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn | [0]")
