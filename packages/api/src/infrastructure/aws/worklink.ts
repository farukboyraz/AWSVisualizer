import { infoPageAdapter } from './info-page.js';

/** Amazon WorkLink: shut down by AWS on 30 November 2021 - information page only. */
export const workLinkAdapter = infoPageAdapter({
  title: "Amazon WorkLink",
  subtitle: "Secure mobile access to internal websites",
  about: "Rendered internal web apps on mobile devices without a VPN.",
  why: "AWS shut WorkLink down on 30 November 2021, so there are no fleets to list.",
  discontinued: "30 November 2021",
  replacement: "Amazon WorkSpaces Secure Browser (formerly WorkSpaces Web).",
  console: (r) => `https://${r}.console.aws.amazon.com/workspaces-web/home?region=${r}`,
});
