import { infoPageAdapter } from './info-page.js';

/** CodeCatalyst: information page (no public API for AWS profiles). */
export const codeCatalystAdapter = infoPageAdapter({
  title: 'CodeCatalyst',
  subtitle: 'Unified software development service',
  about: 'Spaces, projects, source repositories, workflows (CI/CD), issues and dev environments in one service at codecatalyst.aws.',
  why: 'CodeCatalyst signs in with an AWS Builder ID and its API takes a CodeCatalyst personal access token - not the AWS profiles (IAM / IAM Identity Center) this app uses.',
  console: () => 'https://codecatalyst.aws/',
  extra: [['CLI', 'aws codecatalyst … with a personal access token (aws configure sso --use-builder-id)']],
});
