import { infoPageAdapter } from './info-page.js';

/** AWS Elemental MediaStore: shut down by AWS on 12 November 2025 - information page only. */
export const mediaStoreAdapter = infoPageAdapter({
  title: "AWS Elemental MediaStore",
  subtitle: "Media-optimized storage",
  about: "Low-latency origin storage for live and on-demand video (containers with CORS, lifecycle and access policies).",
  why: "AWS shut MediaStore down on 12 November 2025, so there are no containers to list.",
  discontinued: "12 November 2025",
  replacement: "Amazon S3 (with CloudFront) or AWS Elemental MediaPackage as the origin.",
  console: (r) => `https://${r}.console.aws.amazon.com/mediapackage/home?region=${r}`,
});
