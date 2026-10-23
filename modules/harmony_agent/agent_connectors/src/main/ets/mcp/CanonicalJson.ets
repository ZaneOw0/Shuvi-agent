function compareText(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function encode(value: Object): string {
  if (value === null) return 'null';
  if (typeof value === 'string' || typeof value === 'boolean' || typeof value === 'number') {
    const encoded: string | undefined = JSON.stringify(value);
    if (encoded === undefined) throw new Error('value is not JSON serializable');
    return encoded;
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    let result: string = '[';
    for (let index: number = 0; index < items.length; index++) {
      if (index > 0) result += ',';
      result += encode(items[index]);
    }
    return result + ']';
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(record).sort(compareText);
  let result: string = '{';
  let written: number = 0;
  for (let index: number = 0; index < keys.length; index++) {
    const child: Object = record[keys[index]];
    if (child === undefined) continue;
    if (written > 0) result += ',';
    result += JSON.stringify(keys[index]) + ':' + encode(child);
    written++;
  }
  return result + '}';
}

export function canonicalJson(value: Object): string {
  return encode(value);
}

export function parseJsonObject(value: string): Object {
  const parsed: Object = JSON.parse(value) as Object;
  if (parsed === null || typeof parsed === 'string' || typeof parsed === 'number' || typeof parsed === 'boolean' ||
    Array.isArray(parsed)) {
    throw new Error('tool arguments must be a JSON object');
  }
  return parsed;
}
