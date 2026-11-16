import { infoPageAdapter } from './info-page.js';

/** AWS OpsWorks: shut down by AWS on 1 May 2024 - information page only. */
export const opsWorksAdapter = infoPageAdapter({
  title: "AWS OpsWorks",
  subtitle: "Chef / Puppet configuration management",
  about: "Configuration management with Chef and Puppet: OpsWorks Stacks, OpsWorks for Chef Automate and OpsWorks for Puppet Enterprise.",
  why: "AWS shut every OpsWorks variant down on 1 May 2024, so there are no stacks to list.",
  discontinued: "1 May 2024",
  replacement: "AWS Systems Manager (State Manager, Run Command, Application Manager).",
  console: (r) => `https://${r}.console.aws.amazon.com/systems-manager/home?region=${r}`,
});
