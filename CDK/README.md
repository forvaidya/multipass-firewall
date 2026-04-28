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

Once deployed, you can connect to the instance using:

- **AWS Systems Manager Session Manager** (recommended - no SSH key required):
  ```bash
  aws ssm start-session --target <instance-id> --region ap-south-1
  ```

- **SSH** (if you configure a key pair):
  ```bash
  ssh -i <key-pair> ubuntu@<instance-public-ip>
  ```

## Outputs

After deployment, the CDK will output:
- Instance ID
- Private IP address
- Public IP address (if applicable)
