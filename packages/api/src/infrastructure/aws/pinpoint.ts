import { infoPageAdapter } from './info-page.js';

/** Amazon Pinpoint: shut down by AWS on 30 October 2026 - information page only. */
export const pinpointAdapter = infoPageAdapter({
  title: "Amazon Pinpoint",
  subtitle: "Customer engagement (campaigns, journeys)",
  about: "Projects with segments, campaigns, journeys and analytics over email, SMS and push (closed to new customers from May 2025).",
  why: "AWS shut Pinpoint down on 30 October 2026, so there are no projects to list.",
  discontinued: "30 October 2026",
  replacement: "Amazon Connect (outbound campaigns, journeys), AWS End User Messaging for SMS / push, Amazon SES for email.",
  console: (r) => `https://${r}.console.aws.amazon.com/connect/home?region=${r}`,
});
