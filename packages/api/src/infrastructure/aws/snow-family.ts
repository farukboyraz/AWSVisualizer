import { infoPageAdapter } from './info-page.js';

/** AWS Snow Family: shut down by AWS on 12 November 2025 - information page only. */
export const snowAdapter = infoPageAdapter({
  title: "AWS Snow Family",
  subtitle: "Snowball Edge data transfer devices",
  about: "Physical devices (Snowball Edge, Snowcone, Snowmobile) to move data into AWS offline and run edge compute.",
  why: "AWS shut Snowball Edge down on 12 November 2025 (Snowmobile on 14 March 2024), so there are no jobs to list.",
  discontinued: "12 November 2025",
  replacement: "AWS DataSync or AWS Data Transfer Terminal for large transfers; AWS Outposts for edge compute.",
  console: (r) => `https://${r}.console.aws.amazon.com/datasync/home?region=${r}`,
});
