import { infoPageAdapter } from './info-page.js';

/** AWS RoboMaker: shut down by AWS on 10 September 2025 - information page only. */
export const roboMakerAdapter = infoPageAdapter({
  title: "AWS RoboMaker",
  subtitle: "Robotics simulation",
  about: "Simulation jobs, worlds and fleets for ROS robot applications.",
  why: "AWS shut RoboMaker down on 10 September 2025, so there are no simulation jobs to list.",
  discontinued: "10 September 2025",
  replacement: "AWS Batch (containerized simulations) with your own ROS / Gazebo images.",
  console: (r) => `https://${r}.console.aws.amazon.com/batch/home?region=${r}`,
});
