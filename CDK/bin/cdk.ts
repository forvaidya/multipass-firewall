#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { FirewallStack } from '../lib/firewall-stack';

const app = new cdk.App();

new FirewallStack(app, 'FirewallStack', {
  env: {
    region: 'ap-south-1', // Mumbai region
    account: process.env.CDK_DEFAULT_ACCOUNT,
  },
  description: 'CDK stack for firewall-test VM with Ubuntu Graviton',
});
