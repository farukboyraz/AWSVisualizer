import { infoPageAdapter } from './info-page.js';

/** Amazon Elastic Transcoder: shut down by AWS on 13 November 2025 - information page only. */
export const elasticTranscoderAdapter = infoPageAdapter({
  title: "Amazon Elastic Transcoder",
  subtitle: "File-based video transcoding",
  about: "Pipelines, presets and jobs that converted media files in S3 into playback formats.",
  why: "AWS shut Elastic Transcoder down on 13 November 2025, so there are no pipelines to list.",
  discontinued: "13 November 2025",
  replacement: "AWS Elemental MediaConvert (AWS published migration guidance and job-template conversion scripts).",
  console: (r) => `https://${r}.console.aws.amazon.com/mediaconvert/home?region=${r}`,
});
