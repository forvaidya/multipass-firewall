# Falco Firewall on AWS Deployment Guide

## Architecture Overview

```
┌─────────────────────────────────┐
│   EC2 Instance (Public Subnet)   │
│                                  │
│  ┌────────────────────────────┐ │
│  │  Your Application          │ │
│  └────────────┬───────────────┘ │
│               │                 │
│  ┌────────────▼───────────────┐ │
│  │  Falco Firewall            │ │
│  │  - Detection (Falco)       │ │
│  │  - Enforcement (nftables)  │ │
│  │  - DNS Resolution          │ │
│  └────────────┬───────────────┘ │
│               │                 │
└───────────────┼─────────────────┘
                │
        ┌───────┴─────────────────┐
        │                         │
    ┌───▼──────┐         ┌────────▼────┐
    │AWS APIs  │         │Metadata Svc │
    │SNS, SQS  │         │169.254...   │
    │S3, etc   │         └─────────────┘
    └──────────┘
```

## Prerequisites

1. **EC2 Instance**: Ubuntu 20.04+ or Amazon Linux 2
2. **Kernel**: 5.8+ (required for eBPF)
3. **Security Group**: Outbound rules configured
4. **IAM Role**: For CloudWatch and Secrets Manager access

## Step 1: Prepare EC2 Instance

### User Data Script

```bash
#!/bin/bash
set -e

# Update system
sudo apt-get update
sudo apt-get upgrade -y

# Install dependencies
sudo apt-get install -y \
    git \
    python3-pip \
    linux-headers-$(uname -r) \
    build-essential \
    curl

# Clone firewall
cd /opt
sudo git clone https://github.com/your-org/multipass-firewall.git
cd multipass-firewall

# Run setup (will require interaction or --yes flag)
sudo ./scripts/setup.sh --yes

# Start services
sudo systemctl enable falco-firewall-enforce
sudo systemctl start falco-firewall-enforce
```

### IAM Role Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeSecurityGroups"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/ec2/firewall-violations:*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:firewall/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*"
    }
  ]
}
```

## Step 2: Configure for AWS Services

### Edit Policy for Your Services

```yaml
# /etc/falco-firewall/policy.yaml

aws:
  regions:
    - us-east-1
    - us-west-2
  metadata_service_enabled: true
  service_discovery_enabled: true

allowed:
  aws_services:
    # Enable only services your app uses
    - name: sns
      protocol: tcp
      ports: [443]

    - name: s3
      protocol: tcp
      ports: [443]

    - name: dynamodb
      protocol: tcp
      ports: [443]

    - name: cloudwatch
      protocol: tcp
      ports: [443]

    - name: secretsmanager
      protocol: tcp
      ports: [443]

    - name: kms
      protocol: tcp
      ports: [443]

  # Metadata service (required)
  ip_addresses:
    - "169.254.169.254/32:80"
    - "169.254.169.254/32:443"

  # Any public dependencies
  domains:
    - domain: "registry.npmjs.org"
      protocol: tcp
      ports: [443]

# CloudWatch integration for monitoring
alerts:
  channels:
    - type: cloudwatch
      enabled: true
      log_group: "/aws/ec2/firewall-violations"
      stream_name: "instance-$(hostname)"

logging:
  log_file: "/var/log/falco-firewall/enforcement.log"
  deny_log_file: "/var/log/falco-firewall/denied.log"
```

## Step 3: Deployment Methods

### Option A: CloudFormation

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'EC2 instance with Falco firewall'

Resources:
  FirewallSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for firewall testing
      SecurityGroupEgress:
        # Allow all outbound (firewall manages at kernel level)
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
      SecurityGroupIngress:
        # SSH from your IP
        - IpProtocol: tcp
          FromPort: 22
          ToPort: 22
          CidrIp: YOUR_IP/32

  FirewallInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: ami-0c55b159cbfafe1f0  # Ubuntu 22.04
      InstanceType: t3.medium
      IamInstanceProfile: !Ref InstanceProfile
      SecurityGroupIds:
        - !Ref FirewallSecurityGroup
      UserData:
        Fn::Base64: |
          #!/bin/bash
          # Installation script here

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - !Ref InstanceRole

  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
      Policies:
        - PolicyName: FirewallPolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - logs:CreateLogGroup
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                Resource: arn:aws:logs:*:*:log-group:/aws/ec2/firewall-violations:*
```

### Option B: Terraform

```hcl
resource "aws_instance" "firewall" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  iam_instance_profile   = aws_iam_instance_profile.firewall.name
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.firewall.id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    policy_config = file("${path.module}/config/policy.yaml")
  }))

  tags = {
    Name = "falco-firewall-instance"
  }
}

resource "aws_security_group" "firewall" {
  name = "falco-firewall-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

## Step 4: Monitoring

### CloudWatch Integration

Logs automatically sent to:
- **Log Group**: `/aws/ec2/firewall-violations`
- **Streams**: Per-instance streams based on hostname

View logs:

```bash
aws logs tail /aws/ec2/firewall-violations --follow
```

### Create CloudWatch Alarms

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name falco-firewall-violations \
  --alarm-description "Alert on firewall policy violations" \
  --metric-name ViolationCount \
  --namespace FalcoFirewall \
  --statistic Sum \
  --period 300 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1
```

## Step 5: Testing

### From EC2 Instance

```bash
# Check status
sudo make status

# Test allowed service
curl -v https://sqs.us-east-1.amazonaws.com/

# View violations
tail -f /var/log/falco-firewall/denied.log

# Monitor in real-time
watch -n 1 'sudo nft list chain inet filter firewall_out'
```

### From Local Machine

```bash
# SSH into instance
ssh -i key.pem ec2-user@instance-ip

# Run tests
sudo make test

# Get logs
scp -i key.pem \
  ec2-user@instance-ip:/var/log/falco-firewall/enforcement.log \
  ./logs/

# Monitor
ssh -i key.pem ec2-user@instance-ip \
  'tail -f /var/log/falco-firewall/denied.log'
```

## Common AWS Service Endpoints

These are automatically resolved by region:

```
SNS:          https://<region>.sns.amazonaws.com
SQS:          https://<region>.sqs.amazonaws.com
S3:           https://s3.<region>.amazonaws.com
DynamoDB:     https://<region>.dynamodb.amazonaws.com
CloudWatch:   https://monitoring.<region>.amazonaws.com
KMS:          https://<region>.kms.amazonaws.com
Secrets:      https://<region>.secretsmanager.amazonaws.com
EC2:          https://ec2.<region>.amazonaws.com
```

## Cost Optimization

1. **Disable debug logging** in production
2. **Adjust policy check interval** if not needed frequently
3. **Use spot instances** for test environments
4. **CloudWatch costs**: Minimal (log ingestion is cheap)

## Security Best Practices

1. ✅ Keep instance in **private subnet** if possible (use NAT gateway)
2. ✅ **Restrict security group** to needed AWS services only
3. ✅ **Enable VPC Flow Logs** for additional visibility
4. ✅ **Regularly update** policy to remove unused services
5. ✅ **Monitor CloudWatch logs** for suspicious activity
6. ✅ **Use IMDSv2** only (requires `aws_instance.metadata_options`)

```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"  # IMDSv2 only
  http_put_response_hop_limit = 1
}
```

## Troubleshooting on AWS

See main [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for general issues.

### AWS-Specific Issues

**Issue**: Instance can't resolve AWS service domains

```bash
# Check DNS from instance
nslookup sqs.us-east-1.amazonaws.com

# If fails, check VPC DNS settings
# VPC > DHCP Options > DNS Support should be enabled
```

**Issue**: Metadata service giving 401 errors

```bash
# Check IMDSv2 token generation
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/
```

**Issue**: High CloudWatch costs

```bash
# Reduce log verbosity
sed -i 's/log_level: DEBUG/log_level: INFO/' /etc/falco-firewall/policy.yaml

# Or disable specific log types
# Only log denials, not allows
```
