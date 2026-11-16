import { infoPageAdapter } from './info-page.js';

/** AWS App Mesh: shut down by AWS on 30 September 2026 - information page only. */
export const appMeshAdapter = infoPageAdapter({
  title: "AWS App Mesh",
  subtitle: "Service mesh (Envoy) for microservices",
  about: "A managed service mesh: virtual services, routers, nodes and gateways with Envoy sidecars for ECS, EKS and EC2.",
  why: "AWS shut App Mesh down on 30 September 2026, so there are no meshes to list.",
  discontinued: "30 September 2026",
  replacement: "Amazon ECS Service Connect (ECS) or Amazon VPC Lattice (EKS / multi-service networking).",
  console: (r) => `https://${r}.console.aws.amazon.com/vpc/home?region=${r}#Services:`,
});
