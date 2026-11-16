import { infoPageAdapter } from './info-page.js';

/** Amazon Honeycode: shut down by AWS on 29 February 2024 - information page only. */
export const honeycodeAdapter = infoPageAdapter({
  title: "Amazon Honeycode",
  subtitle: "No-code app builder",
  about: "Spreadsheet-backed no-code apps for teams (workbooks, tables, app screens).",
  why: "AWS shut Honeycode down on 29 February 2024 and removed its SDK, so there is nothing to list.",
  discontinued: "29 February 2024",
  replacement: "AWS App Studio or Amazon Q Apps for low-code apps.",
  console: (r) => `https://${r}.console.aws.amazon.com/appstudio/home?region=${r}`,
});
