#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { FirewallStack } from '../lib/firewall-stack';

const app = new cdk.App();

new FirewallStack(app, 'FirewallStack', {
  env: {
    region: 'ap-south-1', // Mumbai region
    account: '521170656618', // AWS account ID
  },
  description: 'CDK stack for firewall-test VM with Ubuntu Graviton',
});
