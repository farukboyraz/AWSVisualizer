import { infoPageAdapter } from './info-page.js';

/** Amazon Q Developer (formerly CodeWhisperer): information page (no public API for AWS profiles). */
export const qDeveloperAdapter = infoPageAdapter({
  title: 'Amazon Q Developer',
  subtitle: 'Formerly CodeWhisperer',
  about: 'AI coding assistant for IDEs and the command line (code suggestions, chat, security scans, /dev and /transform agents). CodeWhisperer became part of Amazon Q Developer in April 2024.',
  why: 'Q Developer profiles and subscriptions are managed in the console (through IAM Identity Center); there is no public API to list them with a profile.',
  console: (r) => `https://${r}.console.aws.amazon.com/amazonq/developer?region=${r}`,
  extra: [['IDE plugins', 'VS Code, JetBrains, Visual Studio, Eclipse'], ['CLI', 'q (brew install amazon-q)']],
});
