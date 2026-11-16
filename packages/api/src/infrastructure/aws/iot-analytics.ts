import { infoPageAdapter } from './info-page.js';

/** AWS IoT Analytics: shut down by AWS on 15 December 2025 - information page only. */
export const iotAnalyticsAdapter = infoPageAdapter({
  title: "AWS IoT Analytics",
  subtitle: "Analytics for IoT device data",
  about: "Channels, pipelines, data stores and datasets for cleaning and querying IoT telemetry (closed to new customers from July 2024).",
  why: "AWS shut IoT Analytics down on 15 December 2025, so there are no channels to list.",
  discontinued: "15 December 2025",
  replacement: "IoT Core rules \u2192 Kinesis Data Firehose / S3, then Glue + Athena or Timestream; AWS IoT SiteWise for industrial data.",
  console: (r) => `https://${r}.console.aws.amazon.com/iot/home?region=${r}`,
});
