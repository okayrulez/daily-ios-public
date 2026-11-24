import { sha256 } from '@noble/hashes/sha2.js';

// JavaScriptCore has no TextEncoder.
export function utf8(text: string): Uint8Array {
  const bytes: number[] = [];
  for (const char of text) {
    let cp = char.codePointAt(0)!;
    if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;
    if (cp < 0x80) bytes.push(cp);
    else if (cp < 0x800) bytes.push(0xc0 | cp >> 6, 0x80 | cp & 63);
    else if (cp < 0x10000) bytes.push(0xe0 | cp >> 12, 0x80 | cp >> 6 & 63, 0x80 | cp & 63);
    else bytes.push(0xf0 | cp >> 18, 0x80 | cp >> 12 & 63, 0x80 | cp >> 6 & 63, 0x80 | cp & 63);
  }
  return new Uint8Array(bytes);
}
export const hash = (text: string) => Array.from(sha256(utf8(text)), b => b.toString(16).padStart(2, '0')).join('');
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonicalJson).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.entries(value)
    .filter(([, value]) => value !== undefined).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([key, value]) => JSON.stringify(key) + ':' + canonicalJson(value)).join(',') + '}';
  const result = JSON.stringify(value);
  if (result === undefined) throw new Error('Invalid JSON value');
  return result;
}
export interface SyncRecord { key: string; kind: 'note' | 'journal'; content: string; hash: string }
