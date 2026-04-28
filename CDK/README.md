# Firewall Test VM - AWS CDK

This CDK stack deploys an EC2 instance in the Mumbai (ap-south-1) region with the following specifications:

## Instance Configuration

- **Name**: firewall-test
- **Region**: ap-south-1 (Mumbai)
- **Instance Type**: t4g.small (ARM64 - Graviton)
- **AMI**: Latest Ubuntu 24.04 LTS Graviton
- **IAM Role**: trading-instance-role
- **Storage**: 30 GB GP3 EBS volume
- **SSM Agent**: Pre-installed and enabled

## Prerequisites

1. AWS CLI configured with credentials
2. Node.js and npm installed
3. AWS CDK CLI installed:
   ```bash
   npm install -g aws-cdk
   ```
4. The IAM role `trading-instance-role` must already exist in your AWS account

## Setup

1. Install dependencies:
   ```bash
   npm install
   ```

2. Build the TypeScript:
   ```bash
   npm run build
   ```

## Deployment

1. Synthesize the CloudFormation template:
   ```bash
   cdk synth
   ```

2. Preview the changes:
   ```bash
   cdk diff
   ```

3. Deploy the stack:
   ```bash
   cdk deploy
   ```

## Cleanup

To delete the stack and resources:
```bash
cdk destroy
```

## Accessing the Instance

**SSM Session Manager Only** - No SSH keys configured

Connect to the instance using AWS Systems Manager Session Manager:

```bash
aws ssm start-session --target <instance-id> --region ap-south-1
```

Or via AWS Console: Systems Manager → Session Manager → Start Session

**Requirements for SSM access:**
- trading-instance-role IAM role must have SSM permissions (AmazonSSMManagedInstanceCore)
- VPC must have access to SSM endpoints (via NAT Gateway or VPC Endpoints)

## Outputs

After deployment, the CDK will output:
- Instance ID
- Private IP address
- Public IP address (if applicable)
