import { infoPageAdapter } from './info-page.js';

/** Amazon QLDB: shut down by AWS on 31 July 2025 - information page only. */
export const qldbAdapter = infoPageAdapter({
  title: "Amazon QLDB",
  subtitle: "Quantum Ledger Database",
  about: "A ledger database with an immutable, cryptographically verifiable journal (PartiQL, document model).",
  why: "AWS shut QLDB down on 31 July 2025, so there are no ledgers to list. (The catalog lists it under Database and Blockchain - both open this page.)",
  discontinued: "31 July 2025",
  replacement: "Amazon Aurora PostgreSQL with an audit / history design (AWS published a migration guide).",
  console: (r) => `https://${r}.console.aws.amazon.com/rds/home?region=${r}`,
});
