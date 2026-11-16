import { infoPageAdapter } from './info-page.js';

/** CloudShell: information page (no public API for AWS profiles). */
export const cloudShellAdapter = infoPageAdapter({
  title: 'CloudShell',
  subtitle: 'Browser-based shell with the AWS CLI',
  about: 'A Linux shell in the browser, already signed in as your console user, with the AWS CLI, SDKs and 1 GB of persistent home storage per region.',
  why: 'CloudShell has no public API - environments exist only per console session. The terminal in this app (Dev Tools panel) runs the same AWS CLI with your profiles.',
  console: (r) => `https://${r}.console.aws.amazon.com/cloudshell/home?region=${r}`,
  extra: [['Free', 'Yes (no charge for CloudShell itself)']],
});
