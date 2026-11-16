import { readFileSync, writeFileSync, mkdirSync, chmodSync } from 'fs';
import { join, dirname } from 'path';
import { homedir } from 'os';
import type { AwsProfile, SsoSession } from '../../domain/entities/index.js';

export function getAwsConfigPath(): string {
  return join(homedir(), '.aws', 'config');
}

interface ParsedAwsConfig {
  profiles: AwsProfile[];
  ssoSessions: SsoSession[];
}

export function parseAwsConfig(): ParsedAwsConfig {
  const configPath = getAwsConfigPath();

  let content: string;
  try {
    content = readFileSync(configPath, 'utf-8');
  } catch {
    return { profiles: [], ssoSessions: [] };
  }

  content = content.replace(/\r\n/g, '\n');

  const profiles: AwsProfile[] = [];
  const ssoSessions: SsoSession[] = [];

  let currentProfile: Partial<AwsProfile> | null = null;
  let currentSession: Partial<SsoSession> | null = null;
  let currentType: 'profile' | 'sso-session' | null = null;

  const lines = content.split('\n');

  for (const rawLine of lines) {
    const line = rawLine.trim();

    if (!line || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }

    const profileMatch = line.match(/^\[profile\s+(.+)\]$/);
    const defaultMatch = line.match(/^\[default\]$/);
    const ssoSessionMatch = line.match(/^\[sso-session\s+(.+)\]$/);

    if (profileMatch || defaultMatch) {
      if (currentType === 'profile' && currentProfile?.name) {
        profiles.push(currentProfile as AwsProfile);
      } else if (currentType === 'sso-session' && currentSession?.name) {
        ssoSessions.push(currentSession as SsoSession);
      }

      const name = defaultMatch ? 'default' : profileMatch![1];
      currentProfile = { name };
      currentSession = null;
      currentType = 'profile';
      continue;
    }

    if (ssoSessionMatch) {
      if (currentType === 'profile' && currentProfile?.name) {
        profiles.push(currentProfile as AwsProfile);
      } else if (currentType === 'sso-session' && currentSession?.name) {
        ssoSessions.push(currentSession as SsoSession);
      }

      currentSession = { name: ssoSessionMatch[1] };
      currentProfile = null;
      currentType = 'sso-session';
      continue;
    }

    const kvMatch = line.match(/^([^=]+?)\s*=\s*(.+)$/);
    if (!kvMatch) continue;

    const [, key, value] = kvMatch;
    const trimmedKey = key.trim();
    const trimmedValue = value.trim();

    if (currentType === 'profile' && currentProfile) {
      switch (trimmedKey) {
        case 'region':
          currentProfile.region = trimmedValue;
          break;
        case 'sso_session':
          currentProfile.sso_session = trimmedValue;
          break;
        case 'sso_account_id':
          currentProfile.sso_account_id = trimmedValue;
          break;
        case 'sso_role_name':
          currentProfile.sso_role_name = trimmedValue;
          break;
        case 'sso_start_url':
          currentProfile.sso_start_url = trimmedValue;
          break;
        case 'sso_region':
          currentProfile.sso_region = trimmedValue;
          break;
        case 'output':
          currentProfile.output = trimmedValue;
          break;
        case 'login_session':
          currentProfile.login_session = trimmedValue;
          break;
        case 'credential_process':
          currentProfile.credential_process = trimmedValue;
          break;
      }
    } else if (currentType === 'sso-session' && currentSession) {
      switch (trimmedKey) {
        case 'sso_start_url':
          currentSession.sso_start_url = trimmedValue;
          break;
        case 'sso_region':
          currentSession.sso_region = trimmedValue;
          break;
        case 'sso_registration_scopes':
          currentSession.sso_registration_scopes = trimmedValue;
          break;
      }
    }
  }

  // Save the last section
  if (currentType === 'profile' && currentProfile?.name) {
    profiles.push(currentProfile as AwsProfile);
  } else if (currentType === 'sso-session' && currentSession?.name) {
    ssoSessions.push(currentSession as SsoSession);
  }

  // Profiles that only exist in ~/.aws/credentials (access keys).
  for (const name of credentialsFileProfiles()) {
    const existing = profiles.find((p) => p.name === name);
    if (existing) existing.hasStaticKeys = true;
    else profiles.push({ name, hasStaticKeys: true });
  }

  return { profiles, ssoSessions };
}

export function getAwsCredentialsPath(): string {
  return join(homedir(), '.aws', 'credentials');
}

/** Section names in ~/.aws/credentials that hold an access key. */
function credentialsFileProfiles(): string[] {
  let content: string;
  try {
    content = readFileSync(getAwsCredentialsPath(), 'utf-8').replace(/\r\n/g, '\n');
  } catch {
    return [];
  }
  const names: string[] = [];
  let current: string | null = null;
  for (const raw of content.split('\n')) {
    const line = raw.trim();
    const section = line.match(/^\[([^\]]+)\]$/);
    if (section) {
      current = section[1].trim();
      continue;
    }
    if (current && /^aws_access_key_id\s*=/.test(line) && !names.includes(current)) names.push(current);
  }
  return names;
}

/** "sso" | "login" (aws login) | "keys" (IAM access keys) | "process" | "other". */
export function profileKind(profile: AwsProfile): 'sso' | 'login' | 'keys' | 'process' | 'other' {
  if (profile.sso_session || profile.sso_start_url) return 'sso';
  if (profile.login_session) return 'login';
  if (profile.hasStaticKeys) return 'keys';
  if (profile.credential_process) return 'process';
  return 'other';
}

/** Profile names: letters, digits, dot, dash, underscore. */
export function isValidProfileName(name: string): boolean {
  return /^[A-Za-z0-9._-]{1,64}$/.test(name);
}

/**
 * Writes (or replaces the region of) `[profile <name>]` in ~/.aws/config -
 * `aws login --profile <name>` then fills in its `login_session`.
 */
export function ensureProfileSection(name: string, region: string): void {
  const configPath = getAwsConfigPath();
  let content = '';
  try {
    content = readFileSync(configPath, 'utf-8');
  } catch {
    mkdirSync(dirname(configPath), { recursive: true });
  }
  const header = name === 'default' ? '[default]' : `[profile ${name}]`;
  const lines = content.replace(/\r\n/g, '\n').split('\n');
  const start = lines.findIndex((l) => l.trim() === header);
  if (start === -1) {
    const separator = content.length > 0 && !content.endsWith('\n') ? '\n\n' : content.length > 0 ? '\n' : '';
    writeFileSync(configPath, content + separator + [header, `region = ${region}`, ''].join('\n'), 'utf-8');
    return;
  }
  let end = lines.findIndex((l, i) => i > start && /^\[.+\]$/.test(l.trim()));
  if (end === -1) end = lines.length;
  const regionIndex = lines.findIndex((l, i) => i > start && i < end && /^region\s*=/.test(l.trim()));
  if (regionIndex >= 0) lines[regionIndex] = `region = ${region}`;
  else lines.splice(start + 1, 0, `region = ${region}`);
  writeFileSync(configPath, lines.join('\n'), 'utf-8');
}

/** Adds an access-key profile to ~/.aws/credentials (file mode 600). Refuses to overwrite. */
export function appendAccessKeyProfile(name: string, accessKeyId: string, secretAccessKey: string): void {
  const path = getAwsCredentialsPath();
  let content = '';
  try {
    content = readFileSync(path, 'utf-8');
  } catch {
    mkdirSync(dirname(path), { recursive: true });
  }
  if (content.replace(/\r\n/g, '\n').split('\n').some((l) => l.trim() === `[${name}]`)) {
    throw Object.assign(new Error(`~/.aws/credentials already has a [${name}] section`), { status: 400 });
  }
  const separator = content.length > 0 && !content.endsWith('\n') ? '\n\n' : content.length > 0 ? '\n' : '';
  const block = [`[${name}]`, `aws_access_key_id = ${accessKeyId}`, `aws_secret_access_key = ${secretAccessKey}`, ''].join('\n');
  writeFileSync(path, content + separator + block, { encoding: 'utf-8', mode: 0o600 });
  chmodSync(path, 0o600);
}

export interface NewProfileInput {
  name: string;
  ssoSessionName: string;
  accountId: string;
  roleName: string;
  region: string;
}

/**
 * Appends a new [profile <name>] block to ~/.aws/config so a previously
 * "not set" SSO account/role becomes a regular, usable profile. Generic by
 * design: works for any account/role pair discovered via SSO, not tied to
 * any specific environment.
 */
export function appendProfile(input: NewProfileInput): void {
  const trimmedName = input.name.trim();
  if (!trimmedName) {
    throw new Error('Profile name is required');
  }

  const { profiles } = parseAwsConfig();
  if (profiles.some((p) => p.name === trimmedName)) {
    throw new Error(`A profile named "${trimmedName}" already exists`);
  }

  const configPath = getAwsConfigPath();
  let content = '';
  try {
    content = readFileSync(configPath, 'utf-8');
  } catch {
    content = '';
  }

  const block = [
    `[profile ${trimmedName}]`,
    `sso_session = ${input.ssoSessionName}`,
    `sso_account_id = ${input.accountId}`,
    `sso_role_name = ${input.roleName}`,
    `region = ${input.region}`,
    '',
  ].join('\n');

  const separator = content.length > 0 && !content.endsWith('\n') ? '\n\n' : content.length > 0 ? '\n' : '';
  writeFileSync(configPath, content + separator + block, 'utf-8');
}

/**
 * `https://your-org.awsapps.com/start`, `.../start/`, `.../start/#` and
 * `.../start/#/` (scheme optional) all become `https://<host>/start`.
 * Returns undefined for anything that isn't an access-portal start URL.
 */
export function normalizeStartUrl(raw: string): string | undefined {
  const trimmed = raw.trim();
  const match = trimmed.match(/^(?:https?:\/\/)?([a-z0-9][a-z0-9.-]*[a-z0-9])\/start\/?(?:#\/?)?$/i);
  if (!match) return undefined;
  return `https://${match[1].toLowerCase()}/start`;
}

/** "https://your-org.awsapps.com/start" -> "your-org". */
export function suggestSessionName(startUrl: string): string {
  const host = startUrl.replace(/^https:\/\//, '').split('/')[0];
  const first = host.split('.')[0] || 'aws';
  return first.replace(/[^a-zA-Z0-9_-]/g, '-');
}

/**
 * Makes sure ~/.aws/config has an `[sso-session]` for this portal (the
 * section `aws configure sso` would write) and returns its name. Reuses an
 * existing session with the same start URL instead of adding a duplicate.
 */
export function ensureSsoSession(startUrl: string, region: string, preferredName?: string): { name: string; region: string; created: boolean } {
  const { ssoSessions } = parseAwsConfig();
  const existing = ssoSessions.find((s) => s.sso_start_url && normalizeStartUrl(s.sso_start_url) === startUrl);
  if (existing) {
    return { name: existing.name, region: existing.sso_region || region, created: false };
  }

  const base = (preferredName || suggestSessionName(startUrl)).replace(/[^a-zA-Z0-9_-]/g, '-') || 'aws';
  let name = base;
  for (let i = 2; ssoSessions.some((s) => s.name === name); i++) name = `${base}-${i}`;

  const configPath = getAwsConfigPath();
  let content = '';
  try {
    content = readFileSync(configPath, 'utf-8');
  } catch {
    mkdirSync(dirname(configPath), { recursive: true });
  }
  const block = [`[sso-session ${name}]`, `sso_start_url = ${startUrl}`, `sso_region = ${region}`, 'sso_registration_scopes = sso:account:access', ''].join('\n');
  const separator = content.length > 0 && !content.endsWith('\n') ? '\n\n' : content.length > 0 ? '\n' : '';
  writeFileSync(configPath, content + separator + block, 'utf-8');
  return { name, region, created: true };
}
