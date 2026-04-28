import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

export class FirewallStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Reference existing IAM role
    const iamRole = iam.Role.fromRoleArn(
      this,
      'TradingInstanceRole',
      `arn:aws:iam::${this.account}:role/trading-instance-role`,
      { mutable: false }
    );

    // Get latest Ubuntu 24.04 LTS Graviton AMI for the region
    const ami = ec2.MachineImage.lookup({
      name: 'ubuntu/images/hvm-ssd/ubuntu-noble-24.04-arm64-server-*',
      owners: ['099720109477'], // Canonical
      windows: false,
    });

    // Reference existing VPC
    const vpc = ec2.Vpc.fromLookup(this, 'TradingVpc', {
      vpcId: 'vpc-0de930762cc1966ea',
    });

    // Reference existing subnet
    const subnet = ec2.Subnet.fromSubnetAttributes(this, 'TradingPublicSubnet', {
      subnetId: 'subnet-0a952ff889946e809',
      availabilityZone: 'ap-south-1a',
    });

    // Reference existing security group
    const securityGroup = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'TradingInstanceSG',
      'sg-0d0e5055511a10076'
    );

    // Create EC2 instance
    // NOTE: No SSH key configured - access via SSM Session Manager only
    const instance = new ec2.Instance(this, 'FirewallTestInstance', {
      vpc,
      vpcSubnets: {
        subnets: [subnet],
      },
      instanceType: ec2.InstanceType.of(
        ec2.InstanceClass.T4G,
        ec2.InstanceSize.SMALL
      ),
      machineImage: ami,
      role: iamRole,
      securityGroup,
      associatePublicIpAddress: true,
      keyName: undefined, // SSM-only access, no SSH keys
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(30, {
            deleteOnTermination: true,
            encrypted: false,
            volumeType: ec2.EbsDeviceVolumeType.GP3,
          }),
        },
      ],
    });

    // Add system tools installation via user data
    instance.addUserData(
      '#!/bin/bash',
      'set -e',
      '',
      '# Update package manager',
      'apt-get update',
      '',
      '# Install SSM agent',
      'apt-get install -y amazon-ssm-agent',
      'systemctl enable amazon-ssm-agent',
      'systemctl start amazon-ssm-agent',
      '',
      '# Install Git',
      'apt-get install -y git',
      '',
      '# Install GitHub CLI',
      'curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/trusted.gpg.d/github.gpg > /dev/null',
      'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/github.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null',
      'apt-get update',
      'apt-get install -y gh',
      '',
      '# Install Docker',
      'apt-get install -y docker.io',
      'usermod -aG docker ubuntu',
      'systemctl enable docker',
      'systemctl start docker',
      '',
      '# Install Docker Compose',
      'curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose',
      'chmod +x /usr/local/bin/docker-compose',
      '',
      '# Install AWS CLI v2',
      'apt-get install -y curl unzip',
      'curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"',
      'unzip awscliv2.zip',
      './aws/install',
      'rm -rf aws awscliv2.zip',
      '',
      '# Verify installations',
      'echo "=== Installation Summary ==="',
      'git --version',
      'gh --version',
      'docker --version',
      'docker-compose --version',
      'aws --version',
      'echo "=== All tools installed successfully ==="'
    );

    // Tag the instance with Name
    cdk.Tags.of(instance).add('Name', 'firewall-test');

    // Output instance details
    new cdk.CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
      description: 'Instance ID of firewall-test',
    });

    new cdk.CfnOutput(this, 'InstancePrivateIp', {
      value: instance.instancePrivateIp,
      description: 'Private IP of firewall-test',
    });

    new cdk.CfnOutput(this, 'InstancePublicIp', {
      value: instance.instancePublicIp || 'N/A',
      description: 'Public IP of firewall-test',
    });

    new cdk.CfnOutput(this, 'VpcId', {
      value: vpc.vpcId,
      description: 'VPC ID',
    });

    new cdk.CfnOutput(this, 'SubnetId', {
      value: subnet.subnetId,
      description: 'Subnet ID',
    });

    new cdk.CfnOutput(this, 'AvailabilityZone', {
      value: subnet.availabilityZone,
      description: 'Availability Zone',
    });
  }
}
